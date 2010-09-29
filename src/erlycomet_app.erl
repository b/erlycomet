%% @author Benjamin Black <b@b3k.us>
%% @copyright 2010 Benjamin Black.

%% @doc Callbacks for the erlycomet application.

-module(erlycomet_app).
-author('Benjamin Black <b@b3k.us>').

-behaviour(application).
-export([start/2,stop/1]).


%% @spec start(_Type, _StartArgs) -> ServerRet
%% @doc application start callback for erlycomet.
start(_Type, _StartArgs) ->
	PidFile = case os:getenv("PIDFILE") of false -> "/var/run/erlycomet.pid"; Any -> Any end,
	ok = file:write_file(PidFile, list_to_binary(os:getpid())),
			
  erlycomet_sup:start_link().

%% @spec stop(_State) -> ServerRet
%% @doc application stop callback for erlycomet.
stop(_State) ->
    ok.
