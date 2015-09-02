#!/usr/bin/env ruby
require 'websocket-eventmachine-client'
require 'json'
require 'thread'
require 'base64'
require 'logger'
require_relative 'ensime'
class EnsimeBridge
    attr_accessor :socket, :quiet
    attr_reader :cache
    def get_socket file
        TCPSocket.open("localhost", File.read(file).chomp)
    end
    def is_running? file = nil
        file = file.nil? ? @bridge_file : file
        return false if not File.exists? file
        begin
            get_socket(file).close
        rescue => e
            return false
        end
        true
    end
    def initialize path
        @ensime = Ensime.new(path)
        @quiet = false
        @cache = "#{path}_cache/"
        @queue = Queue.new
        @bridge_file = "#{@cache}bridge"
        @http_file = "#{@cache}http"
        @logger = Logger.new(@cache + "bridge.log", 2, 100000)
    end
    def remote_stop
        if is_running?
            s = get_socket(@bridge_file)
            s.puts "self.stop"
            s.close
        end
    end
    def stop
        @ensime.stop
        exit
    end
    def connect_to_ensime
        url = "ws://127.0.0.1:#{File.read("#{@cache}http").chomp}/jerky"
        @socket = WebSocket::EventMachine::Client.connect(:uri => url)
        @socket.onopen do
            @logger.info "Connected to ensime!"
        end
        @socket.onerror do |err|
            @logger.error err
        end
        @socket.onmessage do |msg, type|
            @logger.info "Received message: #{msg}, type #{type}"
            @queue << msg
        end
        @socket.onclose do |code, reason|
            @logger.info "Disconnected with status code: #{code} #{reason}"
        end
    end
    def json packet
        s = packet.to_json
        @logger.info " to server => #{s}"
        @socket.send s
    end
    def req message
        @i ||= 0
        @i += 1
        json({"callId" => @i,"req" => message})
    end
    def unqueue
        if @queue.size == 0
            nil
        else
            @queue.pop(true)
        end
    end
    def wait_for_ensime
        while not is_running? @http_file
            sleep 0.2
        end
    end
    def send_result result
        if not result.nil? and not result.empty?
            @client.puts result.gsub("\n", "")
        else
            @client.puts "nil"
            return false
        end
        @logger.info result.gsub("\n", "")
        return true
    end
    def run
        @ensime.quiet = quiet
        @ensime.run
        if is_running?
            @logger.info "bridge is already running"
            return
        end
        wait_for_ensime
        @logger.info "ensime is ready"
        Thread.new do
            EventMachine.run do
                connect_to_ensime
            end
        end
        server = TCPServer.new "localhost", 0
        File.write(@bridge_file, server.addr[1])
        while @client = server.accept
            begin
                command = @client.readline.chomp
                while true
                    result = nil
                    @logger.info "command: #{command}"
                    if command.start_with? "{"
                        @socket.send command
                    else
                        result = instance_eval command
                    end
                    if command == "unqueue"
                        break if not send_result result
                    else
                        break
                    end
                end
                @client.close
            rescue => e
                @logger.error e
                @logger.error e.backtrace
            end
        end
    end
    def to_position path, row, col
        i = -1
        File.open(path) do |f|
            (row - 1).times do
                i += f.readline.size
            end
            i += col
        end
        i
    end
    def at_point what, path, row, col, size, where = "range"
        i = to_position path, row, col
        req({"typehint" => what + "AtPointReq",
            "file" => path,
            where => {"from" => i,"to" => i + size}})
    end
    def type path, row, col, size
        at_point "Type", path, row, col, size
    end
    def doc_uri path, row, col, size
        at_point "DocUri", path, row, col, size, "point"
    end
    def complete path, row, col, contents = nil
        i = to_position path, row, col
        fileinfo = {"file"=>path}
        if contents
            fileinfo["contents"] = Base64.decode64(contents.gsub("!EOL!", "\n"))
        end
        req({"point"=>i, "maxResults"=>100,"typehint"=>"CompletionsReq",
            "caseSens"=>true,"fileInfo"=> fileinfo,"reload"=>false})
    end
    def typecheck path
        req({"typehint"=>"TypecheckFilesReq","files" => [path]})
    end
end
EnsimeBridge.new(ARGV.size == 0 ? ".ensime" : ARGV[0]).run if __FILE__ == $0