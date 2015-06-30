-module(shell_commons_test).

-compile(export_all).

-include_lib("eunit/include/eunit.hrl").

some_eunit_test() ->
    % 1/0,
    ?debugMsg("test pass!\n").
