all: dist compile

compile:
	@./rebar compile

clean:
	@./rebar clean

dist:
	@./rebar get-deps

distclean: clean
	@./rebar delete-deps

test:
	@./rebar eunit