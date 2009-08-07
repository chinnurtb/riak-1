ERL          ?= erl
EBIN_DIRS    := $(wildcard deps/*/ebin)
APP          := riak

all:  webmachine erl ebin/$(APP).app

erl:
	@$(ERL) -pa ebin -pa $(EBIN_DIRS) -noinput +B \
	  -eval 'case make:all() of up_to_date -> halt(0); error -> halt(1) end.'

webmachine:
	@(cd deps/webmachine;$(MAKE))

docs:
	@erl -noshell -run edoc_run application '$(APP)' '"."' '[]'
	@cp -r doc/* www/edoc
	@cp README www/
	@cp LICENSE www/
	@cp TODO www/

clean:
	@echo "removing:"
	@rm -fv ebin/*.beam ebin/*.app

ebin/$(APP).app: src/$(APP).app.src
	@echo "generating ebin/riak.app"
	@bash scripts/make_appfile.sh >ebin/riak.app	

dialyzer: erl 
	@dialyzer -Wno_return -c ebin/ | tee priv/log/dialyzer.log

