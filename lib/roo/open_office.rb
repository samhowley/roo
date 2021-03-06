require 'date'
require 'nokogiri'
require 'cgi'
require 'zip/filesystem'
require 'roo/font'

class Roo::OpenOffice < Roo::Base
  # initialization and opening of a spreadsheet file
  # values for packed: :zip
  def initialize(filename, options={})
    packed = options[:packed]
    file_warning = options[:file_warning] || :error

    @only_visible_sheets = options[:only_visible_sheets]
    file_type_check(filename,'.ods','an Roo::OpenOffice', file_warning, packed)
    @tmpdir = make_tmpdir(filename.split('/').last, options[:tmpdir_root])
    @filename = local_filename(filename, @tmpdir, packed)
    #TODO: @cells_read[:default] = false
    Zip::File.open(@filename) do |zip_file|
      if content_entry = zip_file.glob("content.xml").first
        roo_content_xml_path = File.join(@tmpdir, 'roo_content.xml')
        content_entry.extract(roo_content_xml_path)
        decrypt_if_necessary(
          zip_file,
          content_entry,
          roo_content_xml_path,
          options
        )
      else
        raise ArgumentError, 'file missing required content.xml'
      end
    end
    super(filename, options)
    @formula = Hash.new
    @style = Hash.new
    @style_defaults = Hash.new { |h,k| h[k] = [] }
    @table_display = Hash.new { |h,k| h[k] = true }
    @font_style_definitions = Hash.new
    @comment = Hash.new
    @comments_read = Hash.new
  end

  def method_missing(m,*args)
    read_labels
    # is method name a label name
    if @label.has_key?(m.to_s)
      row,col = label(m.to_s)
      cell(row,col)
    else
      # call super for methods like #a1
      super
    end
  end

  # Returns the content of a spreadsheet-cell.
  # (1,1) is the upper left corner.
  # (1,1), (1,'A'), ('A',1), ('a',1) all refers to the
  # cell at the first line and first row.
  def cell(row, col, sheet=nil)
    sheet ||= default_sheet
    read_cells(sheet)
    row,col = normalize(row,col)
    if celltype(row,col,sheet) == :date
      yyyy,mm,dd = @cell[sheet][[row,col]].to_s.split('-')
      return Date.new(yyyy.to_i,mm.to_i,dd.to_i)
    end
    @cell[sheet][[row,col]]
  end

  # Returns the formula at (row,col).
  # Returns nil if there is no formula.
  # The method #formula? checks if there is a formula.
  def formula(row,col,sheet=nil)
    sheet ||= default_sheet
    read_cells(sheet)
    row,col = normalize(row,col)
    @formula[sheet][[row,col]]
  end

  # Predicate methods really should return a boolean
  # value. Hopefully no one was relying on the fact that this
  # previously returned either nil/formula
  def formula?(*args)
    !!formula(*args)
  end

  # returns each formula in the selected sheet as an array of elements
  # [row, col, formula]
  def formulas(sheet=nil)
    sheet ||= default_sheet
    read_cells(sheet)
    if @formula[sheet]
      @formula[sheet].each.collect do |elem|
        [elem[0][0], elem[0][1], elem[1]]
      end
    else
      []
    end
  end

  # Given a cell, return the cell's style
  def font(row, col, sheet=nil)
    sheet ||= default_sheet
    read_cells(sheet)
    row,col = normalize(row,col)
    style_name = @style[sheet][[row,col]] || @style_defaults[sheet][col - 1] || 'Default'
    @font_style_definitions[style_name]
  end

  # returns the type of a cell:
  # * :float
  # * :string
  # * :date
  # * :percentage
  # * :formula
  # * :time
  # * :datetime
  def celltype(row,col,sheet=nil)
    sheet ||= default_sheet
    read_cells(sheet)
    row,col = normalize(row,col)
    if @formula[sheet][[row,col]]
      return :formula
    else
      @cell_type[sheet][[row,col]]
    end
  end

  def sheets
    unless @table_display.any?
      doc.xpath("//*[local-name()='automatic-styles']").each do |style|
        read_table_styles(style)
      end
    end
    doc.xpath("//*[local-name()='table']").map do |sheet|
      if !@only_visible_sheets || @table_display[attr(sheet,'style-name')]
        sheet.attributes["name"].value
      end
    end.compact
  end

  # version of the Roo::OpenOffice document
  # at 2007 this is always "1.0"
  def officeversion
    oo_version
    @officeversion
  end

  # shows the internal representation of all cells
  # mainly for debugging purposes
  def to_s(sheet=nil)
    sheet ||= default_sheet
    read_cells(sheet)
    @cell[sheet].inspect
  end

  # returns the row,col values of the labelled cell
  # (nil,nil) if label is not defined
  def label(labelname)
    read_labels
    unless @label.size > 0
      return nil,nil,nil
    end
    if @label.has_key? labelname
      return @label[labelname][1].to_i,
        ::Roo::Utils.letter_to_number(@label[labelname][2]),
        @label[labelname][0]
    else
      return nil,nil,nil
    end
  end

  # Returns an array which all labels. Each element is an array with
  # [labelname, [row,col,sheetname]]
  def labels(sheet=nil)
    read_labels
    @label.map do |label|
      [ label[0], # name
        [ label[1][1].to_i, # row
          ::Roo::Utils.letter_to_number(label[1][2]), # column
          label[1][0], # sheet
        ] ]
    end
  end

  # returns the comment at (row/col)
  # nil if there is no comment
  def comment(row,col,sheet=nil)
    sheet ||= default_sheet
    read_cells(sheet)
    row,col = normalize(row,col)
    return nil unless @comment[sheet]
    @comment[sheet][[row,col]]
  end

  # returns each comment in the selected sheet as an array of elements
  # [row, col, comment]
  def comments(sheet=nil)
    sheet ||= default_sheet
    read_comments(sheet) unless @comments_read[sheet]
    if @comment[sheet]
      @comment[sheet].each.collect do |elem|
        [elem[0][0],elem[0][1],elem[1]]
      end
    else
      []
    end
  end

  private

  # If the ODS file has an encryption-data element, then try to decrypt.
  # If successful, the temporary content.xml will be overwritten with
  # decrypted contents.
  def decrypt_if_necessary(
    zip_file,
    content_entry,
    roo_content_xml_path, options
  )
    # Check if content.xml is encrypted by extracting manifest.xml
    # and searching for a manifest:encryption-data element

    if manifest_entry = zip_file.glob("META-INF/manifest.xml").first
      roo_manifest_xml_path = File.join(@tmpdir, "roo_manifest.xml")
      manifest_entry.extract(roo_manifest_xml_path)
      manifest = ::Roo::Utils.load_xml(roo_manifest_xml_path)

      # XPath search for manifest:encryption-data only for the content.xml
      # file

      encryption_data = manifest.xpath(
        "//manifest:file-entry[@manifest:full-path='content.xml']"\
        "/manifest:encryption-data"
      ).first

      # If XPath returns a node, then we know content.xml is encrypted

      if !encryption_data.nil?

        # Since we know it's encrypted, we check for the password option
        # and if it doesn't exist, raise an argument error

        password = options[:password]
        if !password.nil?
          perform_decryption(
            encryption_data,
            password,
            content_entry,
            roo_content_xml_path
          )
        else
          raise ArgumentError,
            'file is encrypted but password was not supplied'
        end
      end
    else
      raise ArgumentError, 'file missing required META-INF/manifest.xml'
    end
  end

  # Process the ODS encryption manifest and perform the decryption
  def perform_decryption(
    encryption_data,
    password,
    content_entry,
    roo_content_xml_path
  )
    # Extract various expected attributes from the manifest that
    # describe the encryption

    algorithm_node = encryption_data.xpath("manifest:algorithm").first
    key_derivation_node =
      encryption_data.xpath("manifest:key-derivation").first
    start_key_generation_node =
      encryption_data.xpath("manifest:start-key-generation").first

    # If we have all the expected elements, then we can perform
    # the decryption.

    if !algorithm_node.nil? && !key_derivation_node.nil? &&
        !start_key_generation_node.nil?

      # The algorithm is a URI describing the algorithm used
      algorithm = algorithm_node['manifest:algorithm-name']

      # The initialization vector is base-64 encoded
      iv = Base64.decode64(
        algorithm_node['manifest:initialisation-vector']
      )
      key_derivation_name =
        key_derivation_node['manifest:key-derivation-name']
      key_size = key_derivation_node['manifest:key-size'].to_i
      iteration_count =
        key_derivation_node['manifest:iteration-count'].to_i
      salt = Base64.decode64(key_derivation_node['manifest:salt'])

      # The key is hashed with an algorithm represented by this URI
      key_generation_name =
        start_key_generation_node[
          'manifest:start-key-generation-name'
      ]
        key_generation_size =
          start_key_generation_node['manifest:key-size'].to_i

        hashed_password = password
        key = nil

        if key_generation_name.eql?(
        "http://www.w3.org/2000/09/xmldsig#sha256"
      )
        hashed_password = Digest::SHA256.digest(password)
      else
        raise ArgumentError, 'Unknown key generation algorithm ' +
          key_generation_name
      end

        cipher = find_cipher(
          algorithm,
          key_derivation_name,
          hashed_password,
          salt,
          iteration_count,
          iv
        )

        begin
          decrypted = decrypt(content_entry, cipher)

          # Finally, inflate the decrypted stream and overwrite
          # content.xml
          IO.binwrite(
            roo_content_xml_path,
            Zlib::Inflate.new(-Zlib::MAX_WBITS).inflate(decrypted)
          )
        rescue StandardError => error
          raise ArgumentError,
            'Invalid password or other data error: ' + error.to_s
        end
    else
      raise ArgumentError,
        'manifest.xml missing encryption-data elements'
    end
  end

  # Create a cipher based on an ODS algorithm URI from manifest.xml
  def find_cipher(
    algorithm,
    key_derivation_name,
    hashed_password,
    salt,
    iteration_count,
    iv
  )
    cipher = nil
    if algorithm.eql? "http://www.w3.org/2001/04/xmlenc#aes256-cbc"
      cipher = OpenSSL::Cipher.new('AES-256-CBC')
      cipher.decrypt
      cipher.padding = 0
      cipher.key = find_cipher_key(
        cipher,
        key_derivation_name,
        hashed_password,
        salt,
        iteration_count
      )
      cipher.iv = iv
    else
      raise ArgumentError, 'Unknown algorithm ' + algorithm
    end
    cipher
  end

  # Create a cipher key based on an ODS algorithm string from manifest.xml
  def find_cipher_key(
    cipher,
    key_derivation_name,
    hashed_password,
    salt,
    iteration_count
  )
    if key_derivation_name.eql? "PBKDF2"
      key = OpenSSL::PKCS5.pbkdf2_hmac_sha1(
        hashed_password,
        salt,
        iteration_count,
        cipher.key_len
      )
    else
      raise ArgumentError, 'Unknown key derivation name ' +
        key_derivation_name
    end
    key
  end

  # Block decrypt raw bytes from the zip file based on the cipher
  def decrypt(content_entry, cipher)
    # Zip::Entry.extract writes a 0-length file when trying
    # to extract an encrypted stream, so we read the
    # raw bytes based on the offset and lengths
    decrypted = ""
    File.open(@filename, "rb") do |zipfile|
      zipfile.seek(
        content_entry.local_header_offset +
        content_entry.calculate_local_header_size
      )
      total_to_read = content_entry.compressed_size

      block_size = 4096
      block_size = total_to_read if block_size > total_to_read

      while buffer = zipfile.read(block_size)
        decrypted += cipher.update(buffer)
        total_to_read -= buffer.length

        break if total_to_read == 0

        block_size = total_to_read  if block_size > total_to_read
      end
    end

    decrypted + cipher.final
  end

  def doc
    @doc ||= ::Roo::Utils.load_xml(File.join(@tmpdir, "roo_content.xml"))
  end

  # read the version of the OO-Version
  def oo_version
    doc.xpath("//*[local-name()='document-content']").each do |office|
      @officeversion = attr(office,'version')
    end
  end

  # helper function to set the internal representation of cells
  def set_cell_values(sheet,x,y,i,v,value_type,formula,table_cell,str_v,style_name)
    key = [y,x+i]
    @cell_type[sheet] = {} unless @cell_type[sheet]
    @cell_type[sheet][key] = Roo::OpenOffice.oo_type_2_roo_type(value_type)
    @formula[sheet] = {} unless @formula[sheet]
    if formula
      ['of:', 'oooc:'].each do |prefix|
        if formula[0,prefix.length] == prefix
          formula = formula[prefix.length..-1]
        end
      end
      @formula[sheet][key] = formula
    end
    @cell[sheet] = {} unless @cell[sheet]
    @style[sheet] = {} unless @style[sheet]
    @style[sheet][key] = style_name
    case @cell_type[sheet][key]
    when :float
      @cell[sheet][key] = v.to_f
    when :string
      @cell[sheet][key] = str_v
    when :date
      #TODO: if table_cell.attributes['date-value'].size != "XXXX-XX-XX".size
      if attr(table_cell,'date-value').size != "XXXX-XX-XX".size
        #-- dann ist noch eine Uhrzeit vorhanden
        #-- "1961-11-21T12:17:18"
        @cell[sheet][key] = DateTime.parse(attr(table_cell,'date-value').to_s)
        @cell_type[sheet][key] = :datetime
      else
        @cell[sheet][key] = table_cell.attributes['date-value']
      end
    when :percentage
      @cell[sheet][key] = v.to_f
    when :time
      hms = v.split(':')
      @cell[sheet][key] = hms[0].to_i*3600 + hms[1].to_i*60 + hms[2].to_i
    else
      @cell[sheet][key] = v
    end
  end

  # read all cells in the selected sheet
  #--
  # the following construct means '4 blanks'
  # some content <text:s text:c="3"/>
  #++
  def read_cells(sheet = default_sheet)
    validate_sheet!(sheet)
    return if @cells_read[sheet]

    sheet_found = false
    doc.xpath("//*[local-name()='table']").each do |ws|
      if sheet == attr(ws,'name')
        sheet_found = true
        col = 1
        row = 1
        ws.children.each do |table_element|
          case table_element.name
          when 'table-column'
            @style_defaults[sheet] << table_element.attributes['default-cell-style-name']
          when 'table-row'
            if table_element.attributes['number-rows-repeated']
              skip_row = attr(table_element,'number-rows-repeated').to_s.to_i
              row = row + skip_row - 1
            end
            table_element.children.each do |cell|
              skip_col = attr(cell, 'number-columns-repeated')
              formula = attr(cell,'formula')
              value_type = attr(cell,'value-type')
              v =  attr(cell,'value')
              style_name = attr(cell,'style-name')
              case value_type
              when 'string'
                str_v  = ''
                # insert \n if there is more than one paragraph
                para_count = 0
                cell.children.each do |str|
                  # begin comments
=begin
- <table:table-cell office:value-type="string">
  - <office:annotation office:display="true" draw:style-name="gr1" draw:text-style-name="P1" svg:width="1.1413in" svg:height="0.3902in" svg:x="2.0142in" svg:y="0in" draw:caption-point-x="-0.2402in" draw:caption-point-y="0.5661in">
      <dc:date>2011-09-20T00:00:00</dc:date>
      <text:p text:style-name="P1">Kommentar fuer B4</text:p>
    </office:annotation>
    <text:p>B4 (mit Kommentar)</text:p>
  </table:table-cell>
=end
                  if str.name == 'annotation'
                    str.children.each do |annotation|
                      if annotation.name == 'p'
                        # @comment ist ein Hash mit Sheet als Key (wie bei @cell)
                        # innerhalb eines Elements besteht ein Eintrag aus einem
                        # weiteren Hash mit Key [row,col] und dem eigentlichen
                        # Kommentartext als Inhalt
                        @comment[sheet] = Hash.new unless @comment[sheet]
                        key = [row,col]
                        @comment[sheet][key] = annotation.text
                      end
                    end
                  end
                  # end comments
                  if str.name == 'p'
                    v = str.content
                    str_v += "\n" if para_count > 0
                    para_count += 1
                    if str.children.size > 1
                      str_v += children_to_string(str.children)
                    else
                      str.children.each do |child|
                        str_v += child.content #.text
                      end
                    end
                    str_v.gsub!(/&apos;/,"'")  # special case not supported by unescapeHTML
                    str_v = CGI.unescapeHTML(str_v)
                  end # == 'p'
                end
              when 'time'
                cell.children.each do |str|
                  if str.name == 'p'
                    v = str.content
                  end
                end
              when '', nil, 'date', 'percentage', 'float'
                #
              when 'boolean'
                v = attr(cell,'boolean-value').to_s
              else
                # raise "unknown type #{value_type}"
              end
              if skip_col
                if v != nil or cell.attributes['date-value']
                  0.upto(skip_col.to_i-1) do |i|
                    set_cell_values(sheet,col,row,i,v,value_type,formula,cell,str_v,style_name)
                  end
                end
                col += (skip_col.to_i - 1)
              end # if skip
              set_cell_values(sheet,col,row,0,v,value_type,formula,cell,str_v,style_name)
              col += 1
            end
            row += 1
            col = 1
          end
        end
      end
    end
    doc.xpath("//*[local-name()='automatic-styles']").each do |style|
      read_styles(style)
    end
    if !sheet_found
      raise RangeError
    end
    @cells_read[sheet] = true
    @comments_read[sheet] = true
  end

  # Only calls read_cells because Roo::Base calls read_comments
  # whereas the reading of comments is done in read_cells for Roo::OpenOffice-objects
  def read_comments(sheet=nil)
    read_cells(sheet)
  end

  def read_labels
    @label ||= Hash[doc.xpath("//table:named-range").map do |ne|
      #-
      # $Sheet1.$C$5
      #+
      name = attr(ne,'name').to_s
      sheetname,coords = attr(ne,'cell-range-address').to_s.split('.$')
      col, row = coords.split('$')
      sheetname = sheetname[1..-1] if sheetname[0,1] == '$'
      [name, [sheetname,row,col]]
    end]
  end

  def read_styles(style_elements)
    @font_style_definitions['Default'] = Roo::Font.new
    style_elements.each do |style|
      next unless style.name == 'style'
      style_name = attr(style,'name')
      style.each do |properties|
        font = Roo::OpenOffice::Font.new
        font.bold = attr(properties,'font-weight')
        font.italic = attr(properties,'font-style')
        font.underline = attr(properties,'text-underline-style')
        @font_style_definitions[style_name] = font
      end
    end
  end

  def read_table_styles(styles)
    styles.children.each do |style|
      next unless style.name == 'style'
      style_name = attr(style,'name')
      style.children.each do |properties|
        display = attr(properties,'display')
        next unless display
        @table_display[style_name] = (display == 'true')
      end
    end
  end

  A_ROO_TYPE = {
    "float"      => :float,
    "string"     => :string,
    "date"       => :date,
    "percentage" => :percentage,
    "time"       => :time,
  }

  def self.oo_type_2_roo_type(ootype)
    return A_ROO_TYPE[ootype]
  end

  # helper method to convert compressed spaces and other elements within
  # an text into a string
  def children_to_string(children)
    result = ''
    children.each {|child|
      if child.text?
        result = result + child.content
      else
        if child.name == 's'
          compressed_spaces = child.attributes['c'].to_s.to_i
          # no explicit number means a count of 1:
          if compressed_spaces == 0
            compressed_spaces = 1
          end
          result = result + " "*compressed_spaces
        else
          result = result + child.content
        end
      end
    }
    result
  end

  def attr(node, attr_name)
    if node.attributes[attr_name]
      node.attributes[attr_name].value
    end
  end
end
