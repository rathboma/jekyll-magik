# frozen_string_literal: true

require "json"
require "rbconfig"

module Jekyll
  module Magik
    # Runs image jobs (see Pipeline) in a worker process and returns their
    # replies: { "ok" => true, "width", "height", "bytes" } or
    # { "ok" => false, "error" }.
    #
    # This is #2's form of #4's worker protocol: one spawned worker, one job
    # at a time, waited for. #4 turns it into a pool fed by the render thread
    # without waiting. The worker is started on the first job, so a build
    # whose images are all cached starts none, and it lives as long as the
    # process (`jekyll serve` keeps it between regenerations).
    #
    # Jekyll's process never loads libvips: the worker does (CLAUDE.md,
    # rule 5). `workers: 0` runs jobs in Jekyll's process instead (InProcess).
    class Processor
      WORKER = File.expand_path("worker.rb", __dir__)
      MIN_VIPS = "8.13"
      STOP_TIMEOUT = 5

      # The processor for a config: one worker per process, shared by every
      # site, or InProcess with `workers: 0`.
      def self.for(config)
        config.workers.zero? ? InProcess.new : shared
      end

      def self.shared
        @shared ||= new.tap { |processor| at_exit { processor.stop } }
      end

      def self.vips_missing(detail)
        if detail.to_s.include?("cannot load such file -- vips")
          return "resizing images needs the ruby-vips gem, which the image worker couldn't load " \
                 "(#{detail}). " \
                 "It's a dependency of jekyll-magik: install jekyll-magik with Bundler " \
                 "(`gem \"jekyll-magik\"` in your Gemfile), so that it's in your bundle"
        end

        "resizing images needs libvips #{MIN_VIPS} or newer, which jekyll-magik couldn't load (#{detail}). " \
          "Install it: `sudo apt-get install --no-install-recommends libvips42t64` on Ubuntu 24.04 " \
          "(`libvips42` on older Ubuntu and Debian), `brew install vips` on macOS, `apk add vips` on Alpine"
      end

      attr_reader :pid, :vips_version

      # worker: the script to run (tests give a fake one).
      def initialize(worker: WORKER)
        @worker = worker
      end

      def run(job)
        # A worker that couldn't start won't start for the next job either:
        # say so once per process, not with a new process per image.
        raise @failed_start if @failed_start

        reap_if_dead
        fresh = @pid.nil?
        start if fresh
        line = exchange(job)
        # A worker that was already running may have died while idle: run
        # the job once more on a new one. A job that kills a new worker
        # fails.
        unless line || fresh
          stop
          start
          line = exchange(job)
        end
        return parse(line) if line

        status = stop
        raise Error, "the image worker exited (#{status&.inspect || "status unknown"}) " \
                     "while processing #{job["source"]}"
      end

      # Closes the worker's stdin, which ends it, and waits for it (killing
      # it after STOP_TIMEOUT). Returns its Process::Status.
      def stop
        return nil unless @pid

        pid = @pid
        @pid = nil
        @input.close unless @input.closed?
        status = wait(pid)
        @output.close unless @output.closed?
        status
      end

      private

      # The job's reply line, or nil if the worker is gone.
      def exchange(job)
        @input.puts(JSON.generate(job))
        @output.gets
      rescue Errno::EPIPE, IOError
        nil
      end

      # A worker that died while idle (killed during a long `jekyll serve`)
      # is replaced before the next job.
      def reap_if_dead
        return unless @pid && Process.wait2(@pid, Process::WNOHANG)

        discard
      rescue Errno::ECHILD
        discard
      end

      def discard
        @pid = nil
        @input.close unless @input.closed?
        @output.close unless @output.closed?
      end

      def start
        child_in, @input = IO.pipe
        @output, child_out = IO.pipe
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        @pid = Process.spawn(RbConfig.ruby, @worker, in: child_in, out: child_out)
        child_in.close
        child_out.close
        @input.sync = true
        hello = @output.gets
        hello &&= parse(hello)
        unless hello && hello["ready"]
          stop
          detail = hello ? hello["error"] : "the worker exited"
          raise @failed_start = Error.new(self.class.vips_missing(detail))
        end
        check_version!(hello["vips"])
        seconds = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
        message = format("started an image worker (pid %<pid>d, libvips %<vips>s) in %<seconds>.2fs",
                         pid: @pid, vips: @vips_version, seconds: seconds)
        Jekyll.logger.debug("jekyll-magik:", message)
      end

      def check_version!(version)
        @vips_version = version
        return if Gem::Version.new(version.to_s[/\A[\d.]+/] || "0") >= Gem::Version.new(MIN_VIPS)

        stop
        raise @failed_start = Error.new(self.class.vips_missing("found libvips #{version}"))
      end

      def parse(line)
        JSON.parse(line)
      rescue JSON::ParserError
        stop
        raise Error, "the image worker replied with something that isn't JSON: #{line.strip[0, 200]}"
      end

      def wait(pid)
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + STOP_TIMEOUT
        loop do
          _, status = Process.wait2(pid, Process::WNOHANG)
          return status if status
          break if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

          sleep(0.01)
        end
        Process.kill(:KILL, pid)
        Process.wait2(pid).last
      rescue Errno::ECHILD, Errno::ESRCH
        nil
      end

      # `workers: 0`: jobs run in Jekyll's own process, which loads libvips.
      # For tests and debugging.
      class InProcess
        def run(job)
          load_pipeline
          Pipeline.run(job).merge("ok" => true, "id" => job["id"])
        rescue Error
          raise
        rescue StandardError => e
          { "ok" => false, "error" => "#{e.message.strip} (#{e.class})", "id" => job["id"] }
        end

        def stop; end

        private

        def load_pipeline
          require_relative "pipeline"
        rescue LoadError => e
          raise Error, Processor.vips_missing(e.message)
        end
      end
    end
  end
end
