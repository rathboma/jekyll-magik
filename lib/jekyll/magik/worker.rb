# frozen_string_literal: true

# An image worker: `ruby worker.rb`, spawned by Jekyll::Magik::Processor
# (never forked, since Jekyll's process may not be fork-safe). It loads
# libvips and the pipeline, and nothing of Jekyll's.
#
# The protocol is JSON lines over stdin and stdout:
# - first, the worker says whether it could load libvips:
#   {"ready":true,"vips":"8.15.1","pid":123} or {"ready":false,"error":"..."}
# - then, for each job line on stdin (see Pipeline), one reply line:
#   {"id":...,"ok":true,"width":600,"height":300,"bytes":12345}
#   {"id":...,"ok":false,"error":"..."}
# - it exits when stdin closes.
#
# Its real stdout is kept for the protocol; anything else printed (by Ruby
# or by libvips) goes to stderr.

require "json"

protocol = $stdout.dup
protocol.sync = true
$stdout.reopen($stderr)

begin
  require_relative "pipeline"
rescue LoadError => e
  protocol.puts(JSON.generate("ready" => false, "error" => e.message))
  exit(1)
end

# Jobs never share operations, and a cached load could hand back a file's
# old pixels after it changes during `jekyll serve`.
Vips.cache_set_max(0)
protocol.puts(JSON.generate("ready" => true, "vips" => Vips.version_string, "pid" => Process.pid))

while (line = $stdin.gets)
  id = nil
  reply = begin
    job = JSON.parse(line)
    id = job["id"]
    Jekyll::Magik::Pipeline.run(job).merge("ok" => true)
  rescue StandardError => e
    { "ok" => false, "error" => "#{e.message.strip} (#{e.class})" }
  end
  protocol.puts(JSON.generate(reply.merge("id" => id)))
end
