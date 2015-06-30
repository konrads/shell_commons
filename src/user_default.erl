-module(user_default).

-export([help/0]).

-export([cr/1]).
-export([cre/1]).
-export([e/1]).

help() ->
     shell_default:help(),
     io:format("** user extended commands **
cr(Module)  -- compile and reload M
cre(Module) -- compile, reload and eunit M
e(Module)   -- eunit M"),
     true.

cr(M) when is_atom(M) ->
    Src = src_file(M),
    EbinDir = filename:dirname(filename:dirname(Src)) ++ "/ebin",
    {ok, Cwd} = file:get_cwd(),
    file:set_cwd(EbinDir),
    % src relative to ebin
    SrcFromEbin = re:replace(Src, ".*src/", "../src/", [{return, list}]),
    try
        {ok, _} = compile:file(SrcFromEbin),
        code:purge(M),
        code:load_file(M)
    after file:set_cwd(Cwd)
    end.

e(M) when is_atom(M) ->
    eunit:test(M).

cre(M) when is_atom(M) ->
    cr(M),
    e(M).

%% internals
src_file(M) ->
    case code:where_is_file(atom_to_list(M) ++ ".beam") of
        non_existing -> throw(non_existing);
        MF ->
            % crude replacement of .beam with .erl, src with ebin
            SF = re:replace(MF, "\\.beam", "\\.erl", [{return, list}]),
            re:replace(SF, "ebin/", "src/", [{return, list}])
    end.
