require "fcntl"
require "socket"
require "json"
require "json/add/core"

module Utils
  def self.safe_fork(&_block)
    Dir.mktmpdir("homebrew", HOMEBREW_TEMP) do |tmpdir|
      UNIXServer.open("#{tmpdir}/socket") do |server|
        read, write = IO.pipe

        pid = fork do
          begin
            ENV["HOMEBREW_ERROR_PIPE"] = server.path
            server.close
            read.close
            write.fcntl(Fcntl::F_SETFD, Fcntl::FD_CLOEXEC)
            yield
          rescue Exception => e # rubocop:disable Lint/RescueException
            write.write e.to_json
            write.close
            exit!
          else
            exit!(true)
          end
        end

        ignore_interrupts(:quietly) do # the child will receive the interrupt and marshal it back
          begin
            socket = server.accept_nonblock
          rescue Errno::EAGAIN, Errno::EWOULDBLOCK, Errno::ECONNABORTED, Errno::EPROTO, Errno::EINTR
            retry unless Process.waitpid(pid, Process::WNOHANG)
          else
            socket.send_io(write)
            socket.close
          end
          write.close
          data = read.read
          read.close
          Process.wait(pid) unless socket.nil?
          raise ChildProcessError, JSON.parse(data) unless data.nil? || data.empty?
          raise Interrupt if $CHILD_STATUS.exitstatus == 130
          raise "Forked child process failed: #{$CHILD_STATUS}" unless $CHILD_STATUS.success?
        end
      end
    end
  end
end
