#!/bin/sh
# VM Agent — vsock control channel listener
# Listens on vsock port 1024, forks a handler per connection.
# Managed by OpenRC as a service.

exec socat VSOCK-LISTEN:1024,reuseaddr,fork EXEC:/usr/local/bin/vm-agent-handler.sh
