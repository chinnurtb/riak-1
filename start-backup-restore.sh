#!/usr/bin/env bash
# ./start-backup-restore.sh <clustername> <cookie> <ip> <port> <dumpfilename>
# This will:
#  Join riak cluster <clustername> using erlcookie <cookie>
#  via the node listening at <ip>:<port>
#  and overwrite cluster data with that contained in <dumpfilename>
. riak-env.sh
erl -noshell -pa deps/*/ebin -pa ebin -name backup_restore -run riak_backup restore_config $1 $2 -run riak start -run riak_backup do_restore $3 $4 $2 $5 -run init stop

