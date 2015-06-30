%% @doc Stateful trace (recon) server, allows for adding/removing calls, pausing and resuming.
%%      Also, periodically samples and reports on process stats, as per process_info().
%%      Eg. report on processes using more than 1Mb memory, every sec: tracer:trace_proc([{memory, 1000000}], 1000).
-module(tracer).

-export([add/1, add/2, add/3]).
-export([rm/1, rm/2, rm/3]).
-export([clear/0]).
-export([pause/0]).
-export([resume/0]).
-export([list/0]).

-export([trace_proc/2]).
-export([stop_trace_proc/0]).

-export([init/1]).
-export([handle_call/3]).
-export([handle_cast/2]).
-export([handle_info/2]).
-export([terminate/2]).
-export([code_change/3]).

-define(DEFAULT_PROC_STATS,    [current_location, memory, message_queue_len, reductions, total_heap_size, current_stacktrace]).
-define(MEASURABLE_PROC_STATS, [memory, message_queue_len, reductions, total_heap_size]).
-define(format(S, P), lists:flatten(io_lib:format(S, P))).

-record(tracer_state,{
    calls = [],
    num_matches = 0,
    
    trace_proc = false :: boolean(),
    trace_proc_interval = 5000,
    trace_proc_stats_limits = []
}).

%% Public API
add(M) when is_atom(M) -> add2({M, '_', '_'}).
add(M, F) when is_atom(M), is_atom(F) -> add2({M, F, '_'}).
add(M, F, A) when is_atom(M), is_atom(F) -> add2({M, F, A}).

rm(M) when is_atom(M) -> rm2({M, '_', '_'}).
rm(M, F) when is_atom(M), is_atom(F) -> rm2({M, F, '_'}).
rm(M, F, A) when is_atom(M), is_atom(F) -> rm2({M, F, A}).

add2(Call) -> ensure_process_cmd({add, Call}).
rm2(Call) -> ensure_process_cmd({rm, Call}).
pause() -> ensure_process_cmd(pause).
resume() -> ensure_process_cmd(resume).
list() -> ensure_process_cmd(list).

trace_proc(StatsLimits, Interval) when is_list(StatsLimits), is_integer(Interval) ->
    % validate Stats
    StatsLimitsValid = lists:all(
        fun({S,V}) when is_number(V) -> lists:member(S, ?MEASURABLE_PROC_STATS);
           (_) -> false
        end,
        StatsLimits
    ),
    case StatsLimitsValid of
        true -> ensure_process_cmd({trace_proc, StatsLimits, Interval});
        _ -> {error, {invalid_stats_limits, StatsLimits}}
    end.

stop_trace_proc() -> ensure_process_cmd(stop_trace_proc).

clear() ->
    recon_trace:clear(),
    case whereis(?MODULE) of
        undefined -> ignore;
        Pid -> exit(Pid, kill)
    end,
    ok.

%% gen_server callbacks
init([]) -> {ok, #tracer_state{}}.

handle_call({add, {_M, _F, _A}=Call}, _From, #tracer_state{calls=Calls, num_matches=NumMatches}=State) ->
    Calls2 = lists:usort([ Call | Calls ]),
    NumMatches2 = recon_call(Calls2),
    case NumMatches2 of
        NumMatches ->
            % revert
            recon_call(Calls),
            {reply, {error, {invalid_call, Call}}, State};
        _ ->
            {reply, ok, State#tracer_state{calls=Calls2, num_matches=NumMatches2}}
    end;

handle_call({rm, {_M, _F, _A}=Call}, _From, #tracer_state{calls=Calls}=State) ->
    MatchedCalls = find_calls(Call, Calls),
    case MatchedCalls of
        [] -> {reply, [], State};
        _ ->
            Calls2 = Calls -- MatchedCalls,
            NumMatches = recon_call(Calls2),
            {reply, MatchedCalls, State#tracer_state{calls=Calls2, num_matches=NumMatches}}
    end;

handle_call(pause, _From, State) ->
    recon_trace:clear(),
    {reply, ok, State};

handle_call(resume, _From, #tracer_state{calls=Calls}=State) ->
    recon_call(Calls),
    {reply, ok, State};

handle_call(list, _From, #tracer_state{calls=Calls}=State) ->
    {reply, Calls, State};

handle_call({trace_proc, StatsLimits, Interval}, _From, #tracer_state{trace_proc=TraceProc}=State) ->
    State2 = State#tracer_state{trace_proc_stats_limits=StatsLimits, trace_proc_interval=Interval, trace_proc=true},
    case TraceProc of
        true -> ignore;                                              % already tracing, continue
        _ -> erlang:send_after(Interval, self(), sample_trace_proc)  % start tracing memory
    end,
    {reply, ok, State2};

handle_call(stop_trace_proc, _From, #tracer_state{}=State) ->
    {reply, ok, State#tracer_state{trace_proc=false}}.

handle_info(sample_trace_proc, #tracer_state{trace_proc_stats_limits=StatsLimits, trace_proc_interval=Interval, trace_proc=true}=State) ->
    case get_proc_stats(StatsLimits) of
        [] -> ignore;
        ProcStats ->
            ProcStatsStr = string:join([ ?format("- ~p: ~p", [Pid, Stats]) || {Pid, Stats} <- ProcStats ], "\n"), 
            error_logger:error_msg("Procs exceeding stats limits: ~p:~n~s", [StatsLimits, ProcStatsStr])
    end,
    erlang:send_after(Interval, self(), sample_trace_proc),
    {noreply, State};

handle_info(_, State) -> {noreply, State}.

handle_cast(_, State) -> {noreply, State}.
terminate(_, _State) -> recon_trace:clear().
code_change(_OldVersion, State, _Extra) -> {ok, State}.

%% internals
ensure_process_cmd(Cmd) ->
    % ensure process exists
    case whereis(?MODULE) of
        undefined -> {ok, _} = gen_server:start({local, ?MODULE}, ?MODULE, [], [{priority, max}]);
        _ -> ignore
    end,
    gen_server:call(?MODULE, Cmd).

recon_call([]) ->
    recon_trace:clear();
recon_call(Calls) ->
    ReconCalls = [ {M, F, [{A, [], [{return_trace}]}]} || {M, F, A} <- Calls ],
    recon_trace:calls(ReconCalls, {100, 10}, [{scope, local}]).

find_calls({M, F, A}, Calls) ->
    % as per: ets:fun2ms(fun ({M2,F2,A2}) when M2=:=M, F2=:=F, A2=:=A -> true end)
    % where M2=:=M, F2=:=F, A2=:=A are optional
    Conds =
        case M of '_' -> []; _ -> [{'=:=','$1',M}] end ++
        case F of '_' -> []; _ -> [{'=:=','$2',F}] end ++
        case A of '_' -> []; _ -> [{'=:=','$3',A}] end,
    MatchSpec = [{{'$1','$2','$3'},Conds,['$_']}],
    ets:match_spec_run(Calls, ets:match_spec_compile(MatchSpec)).

get_proc_stats(StatsLimits) ->
    Stats = [ S || {S, _V} <- StatsLimits],  % just the stats, without the limits
    Stats2 = lists:usort(Stats ++ ?DEFAULT_PROC_STATS), 
    lists:foldl(
        fun(Pid, Acc) ->
            ProcStats = process_info(Pid, Stats2),
            case ProcStats of
                undefined -> Acc;
                _ ->
                    AboveLimit = lists:all(
                        fun({Stat, Limit}) ->
                            Val = proplists:get_value(Stat, ProcStats), 
                            Val >= Limit
                        end,
                        StatsLimits),
                    case AboveLimit of
                        true -> [{Pid, ProcStats} | Acc];
                        false -> Acc
                    end
            end
        end,
        [],
        processes()).
