%% @author Benjamin Black <b@b3k.us>
%% @copyright 2010 Benjamin Black.

%% @doc Callbacks for the erlycomet application.

-module(erlycomet_app).
-author('Benjamin Black <b@b3k.us>').

-behaviour(application).
-export([start/2, stop/1]).


%% @spec start(_Type, _StartArgs) -> ServerRet
%% @doc application start callback for erlycomet.
start(_Type, _Args) ->
    erlycomet_sup:start_link().

%% @spec stop(_State) -> ServerRet
%% @doc application stop callback for erlycomet.
stop(_State) ->
    ok.
