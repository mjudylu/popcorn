-module(log_stream_fsm).
-author('marc.e.campbell@gmail.com').
-behavior(gen_fsm).

-include("include/popcorn.hrl").
-include_lib("stdlib/include/ms_transform.hrl").
-include_lib("stdlib/include/qlc.hrl").

-define(IDLE_DISCONNECT_TIMER,      5000).

-export([start_link/0]).

-export([init/1,
         handle_event/3,
         handle_sync_event/4,
         handle_info/3,
         terminate/3,
         code_change/4]).


-export([
    'STARTING'/2,
    'STARTING'/3,
    'STREAMING'/2,
    'STREAMING'/3]).

-record(state, {stream                  :: #stream{},
                idle_loops_disconnected :: integer()}).

start_link() -> gen_fsm:start_link(?MODULE, [], []).

send_recent_log_line(0, _, _) -> ok;
send_recent_log_line(_, '$end_of_table', _) -> ok;
send_recent_log_line(Count, Last_Key_Checked, Stream) ->
    Key = case Last_Key_Checked of
              undefined -> mnesia:dirty_last(popcorn_history);
              _         -> mnesia:dirty_prev(popcorn_history, Last_Key_Checked)
          end,

    case Key of
        '$end_of_table' -> ok;
        _               -> Log_Message = lists:nth(1, mnesia:dirty_read(popcorn_history, Key)),
                           case is_filtered_out(Log_Message, Stream#stream.max_timestamp, Stream#stream.applied_filters) of
                               false -> gen_fsm:send_all_state_event(self(), {new_message, older, Log_Message}),
                                        send_recent_log_line(Count - 1, Key, Stream);
                               true  -> send_recent_log_line(Count, Key, Stream)
                           end
    end.

init([]) ->
    process_flag(trap_exit, true),

    gen_fsm:start_timer(?IDLE_DISCONNECT_TIMER, idle_disconnect),

    {ok, 'STARTING', #state{idle_loops_disconnected = 0}}.

'STARTING'({connect, Stream}, State) ->
    %% add to the ets table
    ets:insert(current_log_streams, Stream),
    {next_state, 'STARTING', State#state{stream = Stream}};
'STARTING'({set_client_pid, Pid}, State) ->
    Stream  = State#state.stream,
    Stream2 = lists:nth(1, ets:select(current_log_streams, ets:fun2ms(fun(Stream3) when Stream3#stream.stream_id =:= Stream#stream.stream_id -> Stream3 end))),
    Stream3 = Stream2#stream{client_pid = Pid},
    ets:insert(current_log_streams, Stream3),

    %% when the client pid changes, it's a reconnect or initial connection, so 
    %% we send some log lines down
    Stream3#stream.client_pid ! clear_log,
    gen_fsm:send_event_after(0, init_log_lines),

    {next_state, 'STREAMING', State#state{stream = Stream3}}.
'STARTING'(Other, _From, State) ->
    {noreply, undefined, 'STARTING', State}.

'STREAMING'({timeout, _From, idle_disconnect}, State) ->
    Is_Connected = (State#state.stream)#stream.client_pid =/= undefined andalso
                   erlang:is_process_alive((State#state.stream)#stream.client_pid),
    case Is_Connected of
        true ->  {next_state, 'STREAMING', State#state{idle_loops_disconnected = 0}};
        false -> case State#state.idle_loops_disconnected of
                     4 -> {stop, normal, State};
                     O -> gen_fsm:start_timer(?IDLE_DISCONNECT_TIMER, idle_disconnect),
                          {next_state, 'STREAMING', State#state{idle_loops_disconnected = O + 1}}
                 end
    end;

'STREAMING'(init_log_lines, State) ->
    %% send some log lines, based on the current state,
    %% and update the state so we can use timestamps instead of select/4 in a transaction
    Stream = State#state.stream,
    send_recent_log_line(100, undefined, Stream),
    {next_state, 'STREAMING', State};

'STREAMING'(set_time_stream, State) ->
    %% when we set it to "current", we clear the browser, send the 100 most recent events, and then stream all going forward
    Stream = State#state.stream,
    case Stream#stream.max_timestamp of
        undefined -> ok;
        _         -> Stream#stream.client_pid ! clear_log,
                     gen_fsm:send_event_after(0, init_log_lines)
    end,

    Stream2 = Stream#stream{max_timestamp = undefined},

    {next_state, 'STREAMING', State#state{stream = Stream2}};

'STREAMING'({set_time_previous, Max_Date, Max_Time}, State) ->
    Stream = State#state.stream,

    [MonthS, DayS, YearS]     = string:tokens(binary_to_list(Max_Date), "-"),
    [HourS,  MinModS]         = string:tokens(binary_to_list(Max_Time), ":"),
    [MinS,   ModS]            = string:tokens(MinModS, " "),

    Month  = list_to_integer(MonthS),
    Day    = list_to_integer(DayS),
    Year   = list_to_integer(YearS),
    Minute = list_to_integer(MinS),
    Hour   = case MinModS of
                 "PM" -> list_to_integer(HourS) + 12;
                 _    -> list_to_integer(HourS)
             end,

    Gregorian_Seconds = calendar:datetime_to_gregorian_seconds({{Year, Month, Day}, {Hour, Minute, 0}}),
    Max_Timestamp     = date_util:gregorian_seconds_to_epoch(Gregorian_Seconds) * 1000000,  %% because we use microseconds

    case Stream#stream.max_timestamp of
        Max_Timestamp -> ok;    %% no change
        _             -> Stream#stream.client_pid ! clear_log,
                         gen_fsm:send_event_after(0, init_log_lines)
    end,

    Stream2 = Stream#stream{max_timestamp = Max_Timestamp},
    {next_state, 'STREAMING', State#state{stream = Stream2}};

'STREAMING'({update_severities, New_Severities}, State) ->
    Severity_Filter = lists:map(fun(S) -> list_to_integer(S) end, string:tokens(binary_to_list(New_Severities), ",")),
    Stream          = State#state.stream,
    Applied_Filters = Stream#stream.applied_filters,

    Applied_Filters2 = case proplists:get_value('severities', Applied_Filters) of
                           undefined -> Applied_Filters ++ [{'severities', Severity_Filter}];
                           _         -> proplists:delete('severities', Applied_Filters) ++ [{'severities', Severity_Filter}]
                       end,

    update_filters(Applied_Filters2, Stream#stream.stream_id),

    Stream2 = Stream#stream{applied_filters = Applied_Filters2},

    Stream#stream.client_pid ! clear_log,
    gen_fsm:send_event_after(0, init_log_lines),

    {next_state, 'STREAMING', State#state{stream = Stream2}};
'STREAMING'(Other, State) ->
    {next_state, 'STREAMING', State}.

'STREAMING'(Other, _From, State) ->
    {noreply, undefined, 'STREAMING', State}.

handle_event({new_message, Newer_or_older, Log_Message}, State_Name, State) ->
    Stream    = State#state.stream,
    Should_Stream = Stream#stream.paused =:= false andalso
                    is_pid(Stream#stream.client_pid) andalso
                    is_filtered_out(Log_Message, Stream#stream.max_timestamp, Stream#stream.applied_filters) =:= false,

    case Should_Stream of
        false -> ok;
        true  -> case Newer_or_older of
                     newer -> Stream#stream.client_pid ! {new_message, Log_Message};
                     older -> Stream#stream.client_pid ! {old_message, Log_Message}
                 end
    end,

    {next_state, State_Name, State};

handle_event(toggle_pause, State_Name, State) ->
    Stream = State#state.stream,
    New_Stream = Stream#stream{paused = not Stream#stream.paused},

    %% TODO, update the ets table with the paused state

    {next_state, State_Name, State#state{stream = New_Stream}};

handle_event(Event, StateName, State)                 -> {stop, {StateName, undefined_event, Event}, State}.

handle_sync_event(is_paused, _From, State_Name, State) ->
    Stream = State#state.stream,
    {reply, Stream#stream.paused, State_Name, State};

handle_sync_event(Event, _From, StateName, State)     -> {stop, {StateName, undefined_event, Event}, State}.
handle_info(_Info, StateName, State)                  -> {next_state, StateName, State}.
terminate(_Reason, _StateName, State)                 ->
    Stream_Id = (State#state.stream)#stream.stream_id,
    1 = ets:select_delete(current_log_streams, ets:fun2ms(fun(#stream{stream_id = SID}) when SID =:= Stream_Id -> true end)),
    ok.
code_change(_OldVsn, StateName, StateData, _Extra)    -> {ok, StateName, StateData}.

update_filters(Applied_Filters, Stream_Id) ->
    Stream = lists:nth(1, ets:select(current_log_streams, ets:fun2ms(fun(Stream2) when Stream2#stream.stream_id =:= Stream_Id -> Stream2 end))),
    Stream2 = Stream#stream{applied_filters = Applied_Filters},
    ets:insert(current_log_streams, Stream2).

is_filtered_out(Log_Message, Max_Timestamp, Filters) ->
    Severity_Restricted = not lists:member(Log_Message#log_message.severity, proplists:get_value('severities', Filters, [])),
    Time_Restricted = case Max_Timestamp of
                          undefined -> false;
                          _         -> Log_Message#log_message.timestamp > Max_Timestamp
                      end,

    Severity_Restricted orelse Time_Restricted.
