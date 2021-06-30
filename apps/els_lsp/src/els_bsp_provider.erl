-module(els_bsp_provider).

-behaviour(els_provider).

%% API
-export([ start/1 ]).

%% els_provider functions
-export([ is_enabled/0
        , init/0
        , handle_request/2
        , handle_info/2
        ]).


%%==============================================================================
%% Includes
%%==============================================================================
-include("els_lsp.hrl").
-include_lib("kernel/include/logger.hrl").

%%==============================================================================
%% Types
%%==============================================================================
-type state() :: #{ running := boolean()          % is the BSP server running?
                  , root_uri := uri() | undefined % the root uri
                  , pending := list()             % pending requests
                  }.

%%==============================================================================
%% API
%%==============================================================================
-spec start(uri()) -> ok | {error, term()}.
start(RootUri) ->
  els_provider:handle_request(?MODULE, {start, RootUri}).

%%==============================================================================
%% els_provider functions
%%==============================================================================
-spec init() -> state().
init() ->
  #{ running  => false
   , root_uri => undefined
   , pending  => []
   }.

-spec is_enabled() -> true.
is_enabled() -> true.

-spec handle_request({start, uri()}, state()) -> {ok, state()}.
handle_request({start, RootUri}, #{ running := false } = State) ->
  ?LOG_INFO("Starting BSP server in ~p", [RootUri]),
  case els_bsp_client:start_server(RootUri) of
    {ok, Config} ->
      ?LOG_INFO("BSP server started from config ~p", [Config]),
      enqueue(initialize_bsp),
      {{ok, Config}, State#{ running => true, root_uri => RootUri }};
    {error, Reason} ->
      ?LOG_ERROR("BSP server startup failed: ~p", [Reason]),
      {{error, Reason}, State}
  end.

-spec handle_info(initialize_bsp, state()) -> state().
handle_info(initialize_bsp, #{ running := true, root_uri := Root } = State) ->
  {ok, Vsn} = application:get_key(els_lsp, vsn),
  Params = #{ <<"displayName">>  => <<"Erlang LS BSP Client">>
            , <<"version">>      => list_to_binary(Vsn)
            , <<"bspVersion">>   => <<"2.0.0">>
            , <<"rootUri">>      => Root
            , <<"capabilities">> => #{ <<"languageIds">> => [<<"erlang">>] }
            , <<"data">>         => #{}
            },
  request(<<"build/initialize">>, Params, State);
handle_info({request_finished, Request, Response}, State) ->
  handle_response(Request, Response, State);
handle_info(Msg, State) ->
  case check_response(Msg, State) of
    {ok, NewState} ->
      NewState;
    no_reply ->
      ?LOG_WARNING("Discarding unrecognized message: ~p", [Msg]),
      State
  end.

%%==============================================================================
%% Internal functions
%%==============================================================================
-spec request(binary(), map() | null, state()) -> state().
request(Method, Params, #{ pending := Pending } = State) ->
  RequestId = els_bsp_client:request(Method, Params),
  State#{ pending => [{RequestId, {Method, Params}} | Pending] }.

-spec handle_response({binary(), any()}, any(), state()) -> state().
handle_response({<<"build/initialize">>, _}, Response, State) ->
  ?LOG_INFO("BSP Server initialized: ~p", [Response]),
  ok = els_bsp_client:notification(<<"build/initialized">>),
  request(<<"workspace/buildTargets">>, #{}, State);
handle_response({<<"workspace/buildTargets">>, _}, Response, State0) ->
  Result = maps:get(result, Response, #{}),
  Targets = maps:get(targets, Result, []),
  TargetIds = lists:flatten([ maps:get(id, Target, []) || Target <- Targets ]),
  Params = #{ <<"targets">> => TargetIds },
  State1 = request(<<"buildTarget/sources">>, Params, State0),
  State2 = request(<<"buildTarget/dependencySources">>, Params, State1),
  State2;
handle_response({<<"buildTarget/sources">>, _}, Response, State) ->
  handle_sources(apps_paths,
                 fun(Source) -> maps:get(uri, Source, []) end,
                 Response,
                 State);
handle_response({<<"buildTarget/dependencySources">>, _}, Response, State) ->
  handle_sources(deps_paths,
                 fun(Source) -> Source end,
                 Response,
                 State);
handle_response(Request, Response, State) ->
  ?LOG_WARNING("Unhandled response. [request=~p] [response=~p]",
               [Request, Response]),
  State.

-spec handle_sources(atom(), fun((any()) -> uri()), map(), state()) -> state().
handle_sources(ConfigKey, SourceFun, Response, State) ->
  Result = maps:get(result, Response, #{}),
  Items = maps:get(items, Result, []),
  Sources = lists:flatten([ maps:get(sources, Item, []) || Item <- Items ]),
  Uris = lists:flatten([ SourceFun(Source) || Source <- Sources ]),
  UriMaps = [ uri_string:parse(Uri) || Uri <- Uris ],
  NewPaths = lists:flatten([ maps:get(path, UM, []) || UM <- UriMaps ]),
  OldPaths = els_config:get(ConfigKey),
  AllPaths = lists:usort([ els_utils:to_list(P) || P <- OldPaths ++ NewPaths]),
  els_config:set(ConfigKey, AllPaths),
  els_indexing:start(),
  State.

-spec check_response(any(), state()) -> {ok, state()} | no_reply.
check_response(Msg, #{ pending := Pending } = State) ->
  F = fun({RequestId, Request}) ->
          case els_bsp_client:check_response(Msg, RequestId) of
            {reply, Reply} ->
              enqueue({request_finished, Request, Reply}),
              false;
            _ ->
              true
          end
      end,
  case lists:splitwith(F, Pending) of
    {_, []} ->
      no_reply;
    {Left, [_Matched | Right]} ->
      {ok, State#{ pending => Left ++ Right }}
  end.

-spec enqueue(any()) -> ok.
enqueue(Msg) ->
  self() ! Msg,
  ok.
