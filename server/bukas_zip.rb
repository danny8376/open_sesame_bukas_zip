#encoding:UTF-8
require 'rubygems'
#require 'bundler/setup' # uncomment this if you are using bundler
require 'zip'
require 'open-uri'
require 'socket'
require 'em-http'
require 'logger'

# My own libs
require_relative 'libwebp'
require_relative 'libpng'
require_relative 'libjpeg'

# Ropencc
begin
  require 'ropencc'
  $use_tc2zc_convert = true
rescue LoadError
  $use_tc2zc_convert = false
end

def r(path)
  File.expand_path(path, File.dirname(__FILE__))
end


load r 'open_sesame.secret' # got secret !


if ENV['PORT']  # heroku Owo
  $logger = Logger.new(STDOUT)
  $srv_port = ENV['PORT']
else
  $logger = Logger.new(ARGV[0] == "debug" ? STDOUT : 'log/bukas_zip.log')
  $srv_port = $bukas_zip_srv_port
end




# consts
MAX_PER_IP_CONS = 5
MAX_TOTAL_CONS = 50





module Zip
  class MyZipOutputStream
    include ::Zip::IOExtras::AbstractOutputStream

    attr_accessor :comment

    # Opens the indicated zip file. If a file with that name already
    # exists it will be overwritten.
    def initialize(fileName, stream)
      super()
      @fileName = fileName
      @output_stream = stream
      @entry_set = ::Zip::EntrySet.new
      @compressor = ::Zip::NullCompressor.instance
      @closed = false
      @current_entry = nil
      @comment = nil
      @buffer = ::StringIO.new
    end

    # Same as #initialize but if a block is passed the opened
    # stream is passed to the block and closed when the block
    # returns.
    class << self
      def open(fileName, stream)
        return new(fileName, stream) unless block_given?
        zos = new(fileName, stream)
        yield zos
      ensure
        zos.close if zos
      end
    end

    # Closes the stream and writes the central directory to the zip file
    def close
      return if @closed
      finalize_current_entry
      write_central_directory
      @buffer.close
      @closed = true
    end

    # Closes the current entry and opens a new for writing.
    # +entry+ can be a ZipEntry object or a string.
    def put_next_entry(entryname, comment = nil, extra = nil, compression_method = Entry::DEFLATED,  level = Zlib::NO_COMPRESSION)
      raise ZipError, "zip stream is closed" if @closed
      if entryname.kind_of?(Entry)
        new_entry = entryname
      else
        new_entry = Entry.new(@fileName, entryname.to_s)
      end
      new_entry.comment = comment if !comment.nil?
      if (!extra.nil?)
        new_entry.extra = ExtraField === extra ? extra : ExtraField.new(extra.to_s)
      end
      new_entry.compression_method = compression_method if !compression_method.nil?
      init_next_entry(new_entry, level)
      @current_entry = new_entry
    end

    private

    def finalize_current_entry
      return unless @current_entry
      finish
      @current_entry.compressed_size = @buffer.pos
      @current_entry.size = @compressor.size
      @current_entry.crc = @compressor.crc
      
      # force windows file type
      @current_entry.fstype = ::Zip::FSTYPE_FAT
      
      @current_entry.write_local_entry(@output_stream)
      @output_stream << @buffer.string
      @buffer.close
      @buffer = ::StringIO.new
      
      @current_entry = nil
      @compressor = NullCompressor.instance
    end

    def init_next_entry(entry, level = Zlib::DEFAULT_COMPRESSION)
      finalize_current_entry
      @entry_set << entry
      @compressor = get_compressor(entry, level)
    end

    def get_compressor(entry, level)
      case entry.compression_method
        when Entry::DEFLATED then Deflater.new(@buffer, level)
        when Entry::STORED   then PassThruCompressor.new(@buffer)
      else raise ZipCompressionMethodError,
        "Invalid compression method: '#{entry.compression_method}'"
      end
    end

    def write_central_directory
      cdir = CentralDirectory.new(@entry_set, @comment)
      cdir.write_to_stream(@output_stream)
    end

    protected

    def finish
      @compressor.finish
    end

    public
    # Modeled after IO.<<
    def << (data)
      @compressor << data
    end
  end
end









def encode_str(str, force = "big5", conv = true)
  case force
  when "big5"
    str = Ropencc.conv(:simp_to_trad, str) if $use_tc2zc_convert and conv
    return str.encode("big5", {:invalid => :replace, :undef => :replace})
  when "gbk"
    str = Ropencc.conv(:trad_to_simp, str) if $use_tc2zc_convert and conv
    return str.encode("gbk", {:invalid => :replace, :undef => :replace})
  else # just return what given if unknown options given
    return str
  end
end






$index = File.read r "bukas_zip_index.html"
$favicon = File.read r "bukas_favicon.ico"


$downloading_clients = []

$ready_to_down = false






class BukasZipServer < EventMachine::Protocols::HeaderAndContentProtocol
  
  class EMConnWrapper
    def initialize(conn)
      @conn = conn
      @tell = 0
    end
    def tell
      return @tell
    end
    def << (data)
      return self unless data
      @tell += data.bytesize
      @conn.send_data data
      self
    end
  end
  
  
  
  
  attr_reader :peer_ip, :client_id, :filename
  def post_init
    super
    @peer_port, @peer_ip = Socket.unpack_sockaddr_in(get_peername)
    @client_id = "#{@peer_ip}:#{@peer_port}-#{Time.now.to_i}"
    @os_conn = @bukas_conn = nil
    @bukas_conn_svr = 0
    @read_to_down_check = 0
    @conn_closed = false
    @bukas_servers = []
  end
  
  def unbind
    super
    @conn_closed = true
    # kill admin notify thread if there is
    @notify_thread.kill if @hc_mode == :admin and @notify_thread and @notify_thread.alive?
    end_download
  end
  
  def end_download
    $downloading_clients.delete(self) if $downloading_clients.include?(self)
    @os_conn.close rescue nil if @os_conn
    @bukas_conn.close rescue nil if @bukas_conn
  end
  
  # rewrite receive_line for admin console
  def receive_line(line)
    case @hc_mode
    when :discard_blanks # in this mode, it should be first line OwO
      if line =~ /^ADMIN( WIN)?$/ # triggered console mode
        if admin_allowed?
          @win_mode = $1 == " WIN"
          @hc_mode = :admin
          @notify_thread = nil
          send_data "welcome, admin!\n"
        else
          $logger.fatal "#{@peer_ip} may try to hack admin?"
          bad_request
        end
      else
        super line
      end
    when :admin # process admin commands!
      handle_admin line
    else
      super line
    end
  end
  
  # is admin?
  def admin_allowed?
    $admin_ips.include? @peer_ip
  end
  
  # process admin console
  def handle_admin(cmd)
    case cmd
    when "down"
      $ready_to_down = true
      send_data "down!\n"
    when "up"
      $ready_to_down = false
      send_data "\\ up /\n"
    when "status"
      send_data $ready_to_down ? "down!\n" : "\\ up /\n"
    when "list", "ls"
      $downloading_clients.each { |client| send_data "%-35s : %s\n" % [client.client_id, @win_mode ? encode_str(client.filename) : client.filename]}
      send_data "========== finish ==========\n"
    when "notify"
      if @notify_thread and @notify_thread.alive?
        send_data "already notifying!\n"
      else
        @notify_thread = Thread.fork(self) do |con|
          loop do
            if $downloading_clients.empty?
              con.send_data "all downloads finished\n"
              break
            end
            sleep 1
          end
        end
        send_data "start notifying!\n"
      end
    when "exit"
      send_data "bye!\n"
      close_connection_after_writing
    else
      send_data "wrong command!\n"
    end
  end
    
  # server busy?
  def download_busy? # pass block !
    ip_cons = $downloading_clients.count { |client| client.peer_ip == @peer_ip }
    if $downloading_clients.size > MAX_TOTAL_CONS or ip_cons + 1 > MAX_PER_IP_CONS or $ready_to_down
      if $ready_to_down
        forbidden :down
      elsif $downloading_clients.size > MAX_TOTAL_CONS
        forbidden :total
      else
        forbidden :ip
      end
    else
      yield
    end
  end
  
  # process request
  def receive_request(headers, content)
    @headers = headers_2_hash headers
    
    # for reverse proxies
    if @headers[:x_real_ip] and @headers[:x_real_port] and $trusted_proxies.include? @peer_ip
      @peer_ip = @headers[:x_real_ip]
      @peer_port = @headers[:x_real_port].to_i
      @client_id = "#{@peer_ip}:#{@peer_port}-#{Time.now.to_i}"
    elsif @headers[:x_real_ip] and $trusted_proxies.include? @peer_ip
      @peer_ip = @headers[:x_real_ip]
      @client_id = "#{@peer_ip}:P#{@peer_port}-#{Time.now.to_i}"
    end
    
    request = headers.first.split(" ")
    return bad_request unless request.size == 3
    @method, @uri, @protocol = request
    return not_implemented unless @method == "GET" or @protocol.start_with? "HTTP/"
    # process request
    handle_request
  end
  
  # main request handling
  def handle_request
    case @uri
    when "/"
      send_data "HTTP/1.1 200 OK\r\n" +
                "Content-Type: text/html\r\n" +
                "Connection: close\r\n" +
                "\r\n"
      send_data $index
      close_connection_after_writing
    when "/robots.txt"
      send_data "HTTP/1.1 200 OK\r\n" +
                "Content-Type: text/plain\r\n" +
                "Connection: close\r\n" +
                "\r\n"
      send_data "User-agent: *\nDisallow: /"
      close_connection_after_writing
    when "/favicon.ico"
      send_data "HTTP/1.1 200 OK\r\n" +
                "Content-Type: image/x-icon\r\n" +
                "Connection: close\r\n" +
                "\r\n"
      send_data $favicon
      close_connection_after_writing
    when /^\/\d+\/\d+$/
      download_busy? { handle_single }
    when /^\/\d+\/book(?:(?:\/list|(?:\/options![^\/]+)?\/[\d!]+))$/
      download_busy? { handle_book }
    else
      not_found
    end
  end
  
  # download book
  def handle_book
    # 以下URI分析
    ids = @uri.split("/")
    id = ids[1].to_i
    idstr = id.to_s
    
    
    list_mode = ids[3] == "list"
    
    # 分析書本頁 抓出各話ID & 對應分類(單行OR連載)
    open_sesame_req("/bukas/#{id}/book") do |res|
      @type_list = {}
      @ep_list = {}
      book_name = ""
      non_sort_count = non_sort_count_init = 9000
      type_now = nil
      res.each_line do |line|
        case line
        when /<h1>(.+)<\/h1>/
          book_name = $1.chomp
        when /<h4 data-type="([0-9]+)">(.+)<\/h4>/
          type_now = $1.to_i
          @type_list[type_now] = $2.chomp
          @ep_list[type_now] = [] if list_mode
          non_sort_count = non_sort_count_init
        when /<a href="\/bukas\/([0-9]+)\/view\/\?cid=([0-9]+)"><input type="checkbox" class="check_me" value="([0-9]+)" \/>(.+)<\/a>/
          ep = $2.to_i
          if type_now.nil? || $1 != idstr || $2 != $3
            break
          else
            if list_mode
              @ep_list[type_now].push [ep, $4.chomp]
            else
              sort_val = type_now * 10000 # base - type
              ep_name = $4.chomp
              if ep_name =~ /^\d+$/ # just digits
                sort_val += ep_name.to_i
              else
                sort_val += non_sort_count
                non_sort_count -= 1
              end
              @ep_list[ep] = [type_now, ep_name, sort_val]
            end
          end
        end
      end
      if @type_list.empty? || @ep_list.empty?
        bad_gateway
      elsif list_mode
        send_data "HTTP/1.1 200 OK\r\n" +
                  "Content-Type: text/plain; charset=\"utf-8\"\r\n" +
                  "Connection: close\r\n" +
                  "\r\n"
        @type_list.each do |type_id, type_name|
          send_data "type!#{type_id}!#{type_name}\n"
          @ep_list[type_id].reverse.each { |i| send_data "ep!#{i[0]}!#{i[1]}\n" }
        end
        close_connection_after_writing
      else
        # 分析URL - 選項&下載清單
        has_options = ids[3].start_with?("options!")
        fn_encoding = "big5"
        use_conv = true
        output_format = "jpg"
        if has_options
          options = ids[3][8...ids[3].length].split("!")
          for opt in options
            opt = opt.split ":"
            case opt[0]
            when "force_encoding"
              opt[1] ? ( fn_encoding = opt[1] ) : not_found
            when "no_conversion"
              use_conv = false
            when "output_format"
              opt[1] ? ( output_format = opt[1].downcase ) : not_found
            end
          end
        end

        output_format = "jpg" unless ["jpg", "webp"].include? output_format
        
        eps = []
        
        eps = has_options ? ids[4] : ids[3]
        eps = eps.split("!")
        eps.each_with_index { |val, idx| eps[idx] = val.to_i }
        # sort
        eps.sort! { |a, b| @ep_list[a][2] <=> @ep_list[b][2] }
        
        @file_list = []
        
        download_list(id, eps) do
          @filename = "book-#{book_name}_#{id}_#{rand(10000)}.zip"
          
          # ready to download - add record
          $downloading_clients.push self
          
          start_archiever(fn_encoding, use_conv, output_format)
        end
      end
    end
  end
  
  def download_list(id, eps, &block) # must give block (run after finished fetching)
    # 抓出所有圖片
    ep = eps[0]
    open_sesame_req("/bukas/#{id}/view/?cid=#{ep}") do |res|
      if @conn_closed
        end_download
      elsif res
        ori_size = @file_list.size
        res.each_line do |line|
          if line =~ /<a href="\/bukas\/#{id}\/view\/\?cid=#{ep}&host_flag=\d">([^<]+)<\/a>/
            @bukas_servers.push $1 unless @bukas_servers.include? $1
          else
            @file_list.push ["#{@type_list[@ep_list[ep][0]]}/#{@ep_list[ep][1]}/#{$2}", "#{$1}/#{$2}#{$3}", "#{id}-#{ep}", ep] if line =~ /"\/buka_loader\/[^\/]+\/(.+)\/([^.]+)(.*)\.webp"/
          end
        end
        eps.shift
        if @file_list.size == ori_size
          bad_gateway
        elsif eps.empty?
          yield
        else
          download_list(id, eps, &block)
        end
      else
        bad_gateway
      end
    end
  end
  
  
  # download single ep
  def handle_single
    ids = @uri.split("/")
    id1 = ids[1].to_i
    id2 = ids[2].to_i
    
    open_sesame_req("/bukas/#{id1}/view/?cid=#{id2}") do |res|
      @file_list = []
      book_name = ""
      res.each_line do |line|
        if line =~ /<a href="\/bukas\/#{id1}\/view\/\?cid=#{id2}&host_flag=\d">([^<]+)<\/a>/
          @bukas_servers.push $1 unless @bukas_servers.include? $1
        else
          @file_list.push [$2, "#{$1}/#{$2}#{$3}", "#{id1}-#{id2}", id2] if line =~ /"\/buka_loader\/[^\/]+\/(.+)\/([^.]+)(.*)\.webp"/
        end
        book_name = $1.chomp if line =~ /<h4>(.+)<\/h4>/
      end
      if @file_list.empty?
        bad_gateway
      elsif not @conn_closed
        @filename = "book-#{book_name}_ep_#{id1}_#{id2}.zip"
        
        # ready to download - add record
        $downloading_clients.push self
        
        start_archiever("big5", true)
      end
    end
    
  end
  
  
  
  # request open sesame part
  def create_sesame_con
    @os_conn = EventMachine::HttpRequest.new($open_sesame_url)
  end
  
  def open_sesame_req(path, &block) # must give block
    create_sesame_con unless @os_conn
    req = @os_conn.get :path => path, :keepalive => true, :head => $open_sesame_auth
    req.callback {
      yield req.response
    }
    req.errback {
      if req.error == 'connection closed by server'
        create_sesame_con
        open_sesame_req path, &block
      else
        bad_gateway
      end
    }
  end
  
  # request bukas part
  def create_bukas_con(switch_svr = false)
    @bukas_conn_svr = (@bukas_conn_svr + 1) % @bukas_servers.size if switch_svr
    @bukas_conn = EventMachine::HttpRequest.new("http://#{@bukas_servers[@bukas_conn_svr]}")
    $logger.info "#{@client_id} - Bukas Connecting - #{@bukas_servers[@bukas_conn_svr]}"
  end
  
  def bukas_req(path, retry_count = 0, &block) # must give block
    create_bukas_con unless @bukas_conn
    req = @bukas_conn.get :path => path, :keepalive => true
    req.callback {
      if req.response_header.status == 200
        create_bukas_con unless req.response_header.keepalive?
        yield req.response.force_encoding('binary')
      elsif retry_count >= 3 * @bukas_servers.size # has retried too many times...
        yield false
      else # switch to another server 030
        create_bukas_con true
        bukas_req path, retry_count + 1, &block
      end
    }
    req.errback {
      if req.error == 'connection closed by server'
        create_bukas_con
        bukas_req path, &block
      elsif retry_count >= 3 * @bukas_servers.size
        yield false
      elsif retry_count % 3 == 0
        create_bukas_con true
        bukas_req path, retry_count + 1, &block
      else
        bukas_req path, retry_count + 1, &block
      end
    }
  end
  
  
  # download file & add it to archieve
  def process_file(zos, fn_encoding, use_conv, output_format)
    file_now = @file_list[0]
    bukas_req(file_now[1]) do |res|
      if @conn_closed
        end_download
        zip_end zos
      elsif $ready_to_down and @read_to_down_check != file_now[3]
        zos.put_next_entry(encode_str("下線維修中，請稍後再繼續下載(中斷處為最後下載中的一話or集)"))
        zos.puts "下線維修中，請稍後再繼續下載(中斷處為最後下載中的一話or集)"
        zip_end zos
      elsif res
        $logger.info "#{@client_id} - Saving file - #{file_now[2]} - #{file_now[0]}"
        zos.put_next_entry("#{encode_str(file_now[0], fn_encoding, use_conv)}.#{output_format}")
        res = res[64..-1]
        w, h, d = case output_format
                  when "webp"
                    [-1, -1, res]
                  when "png"
                    WebP.decodeRGBA(res)
                  else # jpg (RGB) is default
                    WebP.decodeRGB(res)
                  end
        if d.empty?
          #process_file(zos, fn_encoding, use_conv, output_format)
          $logger.info "#{@client_id} - bukas wrong! - webp decoding failed - #{file_now[1]}"
          zos.put_next_entry("Something Wrong!!!")
          zos.puts "Something Wrong!!!"
          zip_end zos
        else
          zos.puts case output_format
                   when "webp"
                     d
                   when "png"
                     PNG.encodePNG(w, h, d)
                   else # jpg is default
                     JPEG.encodeJPEG(w, h, d)
                   end
          @read_to_down_check = file_now[3]
          @file_list.shift
          if @file_list.empty?
            $logger.info "#{@client_id} - Download finished!"
            zip_end zos
          else
            process_file(zos, fn_encoding, use_conv, output_format)
          end
        end
      else
        $logger.info "#{@client_id} - bukas wrong! - no data - #{file_now[1]}"
        zos.put_next_entry("Something Wrong!!!")
        zos.puts "Something Wrong!!!"
        zip_end zos
      end
    end
  end
  
  # start archiever !!!
  def start_archiever(fn_encoding, use_conv, output_format)
    send_data "HTTP/1.1 200 OK\r\n" +
              "Content-Type: application/octet-stream\r\n" +
              "Content-Disposition: attachment; filename=\"#{@filename}\";\r\n" +
              "Connection: close\r\n" +
              "\r\n"
    
    zos = Zip::MyZipOutputStream.open(@filename, EMConnWrapper.new(self))
    @read_to_down_check = 0
    process_file(zos, fn_encoding, use_conv, output_format)
  end
  
  def zip_end(zos)
    zos.close
    close_connection_after_writing
  end
  
  
  # error methods
  def bad_request
    send_error "HTTP/1.1 400 Bad request\r\n" +
               "Connection: close\r\n" +
               "Content-type: text/plain\r\n" +
               "\r\n" +
               "Bad Request"
  end
  def forbidden(reason = nil)
    case reason
    when :ip
      msg = "You are downloading too many files simultaneously - Clam down!"
    when :total
      msg = "Server is busy now - try again latter"
    when :down
      msg = "本服務準備下線維修/更新<br\>暫時停止新下載連線<br\>請等待維修/更新結束，稍後再連線"
    else
      msg = "Forbidden"
    end
    send_error "HTTP/1.1 403 Forbidden\r\n" +
               "Content-Type: text/html; charset=\"utf-8\"\r\n" +
               "Connection: close\r\n" +
               "\r\n" +
               msg
  end
  def not_found
    send_error "HTTP/1.1 404 Not Found\r\n" +
               "Content-Type: text/html\r\n" +
               "Connection: close\r\n" +
               "\r\n" +
               "Not Found - Invaild URI"
  end
  def not_implemented
    send_error "HTTP/1.1 501 Not Implemented\r\n" +
               "Connection: close\r\n" +
               "\r\n" +
               "501 Not Implemented"
  end
  def bad_gateway
    $logger.error "bad gateway!\n" +
                  "URI: " + @uri.to_s
    send_error "HTTP/1.1 502 Bad Gateway\r\n" +
               "Content-Type: text/html\r\n" +
               "Connection: close\r\n" +
               "\r\n" +
               "Bad Gateway - Maybe you entered wrong id pair or something strange happened to OpenSesame"
  end
  
  def send_error err_cnt
    send_data err_cnt
    close_connection_after_writing
  end
end




EventMachine.run {
  $logger.info "Server waiting..."

  EventMachine.error_handler { |e|
    $logger.error "error happened\n" +
#                  "URI: #{@uri.to_s}\n" +
                  e.inspect + "\n" +
                  "\t" + e.backtrace.join("\n\t")

#    send_error "HTTP/1.1 500 Internal Server Error\r\n" +
#               "Content-Type: text/html\r\n" +
#               "Connection: close\r\n" +
#               "\r\n" +
#               "Internal Server Error - Please report this to admin"
  }
  
  EventMachine.start_server "0.0.0.0", $srv_port, BukasZipServer
}
