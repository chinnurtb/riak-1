#!/usr/bin/env bash
# ./start-backup-dump.sh <clustername> <cookie> <ip> <port> <dumpfilename>
# This will:
#  Join riak cluster <clustername> using erlcookie <cookie>
#  via the node listening at <ip>:<port>
#  and dump the entire cluster's contents to <dumpfilename>
. riak-env.sh
erl -noshell -pa deps/*/ebin -pa ebin -name backup_dumper -run riak_backup dump_config $1 $2 -run riak start -run riak_backup do_dump $3 $4 $5 -run init stop
