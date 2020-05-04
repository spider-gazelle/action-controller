# Spider-Gazelle Clustering Overview

Spider-Gazelle clustering works by launching multiple processes that share a port binding via `SO_REUSEPORT`

```ruby

  server = HTTP::Server.new(HANDLERS)
  server.bind_tcp(host: '0.0.0.0', port: 3000, reuse_port: true)
  server.listen

```

## Launching

To start clustering we do the following:

1. Grab the processes executable path
1. Remove the clustering arguments so newly launched processes don't also launch processes
1. Keep an array of futures that resolve when the launched processes exit

We avoid using fork as this isn't supported on all platforms.

```ruby

  @processes = [] of Future::Compute(Nil)

  def cluster(count, short_arg, long_arg, args = ARGV.dup)
    process_path = Process.executable_path.not_nil!

    # Removing the clustering arguments and leave the other arguments
    args.reject! { |e| e.starts_with?(long_arg) }
    remove = [] of Int32
    args.each_with_index { |value, index| remove << index if value == short_arg }
    remove.each { |index| args.delete_at(index, 2) }

    # Start the processes
    (0_i64...count).each do
      @processes << future do
        process = nil
        # inherit std outs for logging
        Process.run(process_path, args,
          input: Process::Redirect::Close,
          output: Process::Redirect::Inherit,
          error: Process::Redirect::Inherit
        ) do |ref|
          process = ref
          puts " > worker #{process.pid} started"
        end
        status = $?
        process = process.not_nil!
        if status.success?
          puts " < worker #{process.pid} stopped"
        else
          puts " ! worker process #{process.pid} failed with #{status.exit_status}"
        end
        nil
      end
    end
  end

```

Example usage of the function above

```ruby

workers = 0

# duplicate ARGV as option parser modifies the array
OptionParser.parse(ARGV.dup) do |parser|
  parser.on("-w COUNT", "--workers=COUNT", "number of worker processes to launch") do |w|
      workers = w.to_i
  end
end

# start clustering
cluster(workers, "-w", "--workers")

```

## Terminating

Signals are sent to all child processes automatically.
So we can wait for the child processes to close without explicitly interacting.

```ruby

# Detect ctr-c to shutdown gracefully
Signal::INT.trap do |signal|
  puts " > terminating gracefully"
  spawn { close }

  # We ignore the signal so we can terminate gracefully, otherwise crystal
  # will terminate the process when this fiber yields
  signal.ignore
end

def close
  # Wait for any child processes to close
  @processes.each(&.get)
  # where server is a HTTP::Server
  server.close
end

```
