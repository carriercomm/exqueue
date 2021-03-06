defmodule ExQueue.Server do
  use GenServer

  defmodule State do
    defstruct limit: 1, log: "", queue: [], running: [], done: [], history: %{}, data: %{}
  end

  @name {:global, :exqueue}

  # ---- client API

  def start_link do
    GenServer.start_link(__MODULE__, %State{}, name: @name)
  end

  # args can be a single atom, like :status, or a tuple, like {:q, cmd}, etc.
  def gscall(args) do
    GenServer.call(@name, args)
  end

  # ---- server (callbacks), one for each command

  def handle_call({:q, pwd, cmd}, _from, st) do
    {st, msg} = st
                |> _add_cmd_to_queue(pwd, cmd)
                |> _run_next_in_queue
    {:reply, msg, st}
  end

  def handle_call({:run, pwd, cmd}, _from, st) do
    {st, msg} = st
                |> _add_cmd_to_queue(pwd, cmd, :top)
                |> _run_next_in_queue(:run)
    {:reply, msg, st}
  end

  def handle_call({:limit, _pwd, new}, _from, st) do
    if String.match?(new, ~r/^\d+$/) do
      {st, msg} = st
                  |> struct(limit: String.to_integer(new))
                  |> _run_next_in_queue
                  # ideally, you should do all this in a new fun that sets the
                  # limit, then runs _run_next_in_queue as many times as
                  # needed to fill the queue, instead of adding just *one*
                  # task.  Ignored for now... I don't expect to be making the
                  # limit jump more than one step up.  (Workaround if needed:
                  # just run the same limit command multiple times!)
      {:reply, "ok\n" <> msg, st}
    else
      {:reply, "bad number", st}
    end
  end

  def handle_call({:errors, _pwd}, _from, st) do
    msg = st.history
          |> Enum.filter(fn {_p,h} -> h[:status] end)
          |> Enum.filter(fn {_p,h} -> h[:status] > 0 end)
          |> Enum.into([], &_print_history_item/1)
          |> Enum.join("\n")
    {:reply, msg, st}
  end

  def handle_call({:history, _pwd}, _from, st) do
    msg = Enum.into(st.history, [], &_print_history_item/1) |> Enum.join("\n")
    {:reply, msg, st}
  end

  def handle_call({:jump, _pwd, patt}, _from, st = %State{queue: q}) do
    q1 = Enum.filter(q, fn {_pwd, cmd} ->  String.match?(cmd, ~r(#{patt})i) end)
    q2 = Enum.filter(q, fn {_pwd, cmd} -> !String.match?(cmd, ~r(#{patt})i) end)

    {:reply, "#{Enum.count(q1)} jobs jumped", struct(st, queue: q1 ++ q2)}
  end

  def handle_call({:cancel, _pwd, patt}, _from, st = %State{queue: q}) do
    cancelled = Enum.filter(q, fn {_pwd, cmd} -> String.match?(cmd, ~r(#{patt})i) end)
    msg = Enum.into(cancelled, "", fn x -> "#{inspect x}\n" end)
      <> "#{Enum.count(cancelled)} jobs cancelled"
    st = struct(st, queue: q -- cancelled)
    {:reply, msg, st}
  end

  def handle_call({:redo, _pwd, patt}, _from, st = %State{history: h, queue: q}) do
    # get a list of new jobs
    nj =  h # remember, h is %{pid => %{:cmd => ..., :pwd => ..., ...}}
          |>  Enum.flat_map(fn {_pid, j = %{pwd: pwd, cmd: cmd}} ->
                # completed jobs (i.e., having ':end') with 'cmd' matching 'patt'
                if j[:end] && String.match?(cmd, ~r(#{patt})i),
                  do:   [{pwd, cmd}],
                  else: []
              end)
    msg1 = Enum.into(nj, "", fn x -> "#{inspect x}\n" end)
      <> "#{Enum.count(nj)} jobs queued\n"
    {st, msg2} =  struct(st, queue: nj ++ q)
                  |> _run_next_in_queue
    {:reply, msg1 <> msg2, st}
  end

  def handle_call({:purge, _pwd, patt}, _from, st = %State{history: h}) do
    oh = h

    # remove completed jobs (i.e., having ':end') with 'cmd' matching 'patt' from history...
    h = h
        |>  Enum.filter(fn {_pid, j = %{cmd: cmd}} ->
              !(j[:end] && String.match?(cmd, ~r(#{patt})i))
            end)
        |>  Enum.into(%{})  # get back a map from the list of tuples
    # ... and update state
    st =  struct(st, history: h)

    # remove purged pids from the "done" list and "data" map and update history in one go
    st =  Map.keys(oh) -- Map.keys(h)
          |> Enum.reduce(st, fn pid, st -> _purge(st, pid) end)

    {:reply, "#{Enum.count(oh) - Enum.count(h)} jobs purged", st}
  end

  def handle_call({:status, _pwd}, _from, st) do
    msg = """
      LIMIT: #{st.limit}

      QUEUED:
      #{_print_list(st.queue, st)}
      RUNNING:
      #{_print_list(st.running, st)}
      DONE:
      #{_print_list(st.done, st)}
      LOG/MESSAGES:
      #{st.log}
      """
    # flush the log
    st = struct(st, log: "")
    {:reply, msg, st}
  end

  def handle_call({:peek, _pwd}, from, st) do
    handle_call({:peek, _pwd, "0"}, from, st)
  end
  def handle_call({:peek, _pwd, id}, _from, st) do
    {:reply, _show_data(st, st.running, id), st}
  end

  def handle_call({:print, _pwd}, from, st) do
    handle_call({:print, _pwd, "0"}, from, st)
  end
  def handle_call({:print, _pwd, id}, _from, st) do
    { :reply, _show_data(st, st.done, id), _purge(st, id) }
  end

  def handle_call(x, _from, st) do
    {:reply, """
      Say what?  I can't grok this:
      #{inspect(x)}
      """,
      st
    }
  end

  def handle_cast(x, st) do
    {:noreply, st
      |> _warn("XQ SERVER: unexpected CAST message:")
      |> _warn(inspect(x))
    }
  end

  # :data and :exit_status are the two kinds of messages a port sends
  def handle_info({p, {:data, d}}, st) do
    {:noreply, _add_data(st, p, d)}
  end
  def handle_info({p, {:exit_status, es}}, st) do
    {:noreply, _done(st, p, es)}
  end

  def handle_info(x, st) do
    {:noreply, st
      |> _warn("XQ SERVER: unexpected INFO message:")
      |> _warn(inspect(x))
    }
  end

  # ---- queue handling functions

  # -------- return "state"

  defp _add_cmd_to_queue(st, pwd, cmd),       do: struct(st, queue: st.queue ++ [{pwd, cmd}])
  defp _add_cmd_to_queue(st, pwd, cmd, :top), do: struct(st, queue: [ {pwd, cmd} | st.queue ])

  # -------- return "state", "message"

  defp _run_next_in_queue(st, :run) do
    # save current limit, temp'ly raise it, get stuff done, then set it back
    l = st.limit
    {st, msg} = _run_next_in_queue( struct(st, limit: length(st.running)+1) )
    { struct(st, limit: l), msg }
  end

  defp _run_next_in_queue(st = %State{queue: []}) do
    {st, "ExQueue: queue is empty"}
  end
  defp _run_next_in_queue(st = %State{limit: l, running: r, queue: q}) when length(r) >= l do
    {st, "ExQueue: #{length(r)} jobs running (limit #{l}), #{length(q)} in queue"}
  end
  defp _run_next_in_queue(st = %State{queue: [h|t]}) do
    p = _port_open(h)
    st = struct(st,
      queue:   t,
      running: st.running ++ [ p ],
      history: Map.put(st.history, p, %{begin: _ts, pwd: elem(h,0), cmd: elem(h, 1)})
    )
    {st, "started #{inspect p}: #{inspect h}"}
  end

  # ---- service routines that touch the "state"

  # -------- return "state"

  defp _add_data(st, p, d) do
    struct(st,
      data: Map.update(st.data, p, d, &(&1 <> d))
    )
  end

  defp _done(st, p, es) do
    # todo: add a new field "failed" and update it if es != 0
    st
    |> struct(
        running: st.running -- [p],
        done:    st.done ++ [p],
        history: Map.update!(st.history, p, fn(x) ->
          x |> Map.put(:end, _ts) |> Map.put(:status, es)
        end)
      )
    |> _run_next_in_queue
    |> (fn({st, msg}) -> _warn(st, msg) end).()

  end

  defp _purge(st, id) when is_binary(id) do
    _purge(st, _id2p(st.done, id))
  end
  defp _purge(st, p) do
    struct(st,
      done: st.done -- [p],
      data: Map.delete(st.data, p)
    )
  end

  defp _warn(st, msg) do
    struct(st, log: st.log <> _ts <> ": " <> msg <> "\n")
  end

  # ---- service routines that don't touch the "state"

  defp _port_open({pwd, cmd}) do
    opts = ~w(stderr_to_stdout exit_status binary)a
    cmd = cmd <> " < /dev/null"
    Port.open({:spawn_executable, System.get_env("SHELL")}, [{:cd, pwd}, {:args, ["-c", cmd]} | opts])
  end

  defp _print_list(l, st) do
    Enum.into(l, "", fn p ->
      # print the port number
      inspect(p) <>
      # then the exit status (if any) on the same line as the port number, followed by the command
      case Map.get(st.history, p) do
        nil ->  "\n"
        x   ->
          case x[:status] do
            nil ->  ""
            s   ->  "\t(#{s})"
          end <>
          "\t" <> x.cmd <> "\n"
      end <>
      # and finally the last line of the output, which (hopefully) tells the
      # user something useful!
      case Map.get(st.data, p) do
        nil ->  ""
        x   ->  "\t" <> (x |> String.rstrip |> String.replace(~r(.*\n), "")) <> "\n"
      end
    end)
  end

  defp _show_data(st, list, id), do: _show_data(st, _id2p(list, id))

  defp _show_data(_st, nil), do: "(job number out of bounds)"
  defp _show_data(st, p),    do: """
    #{_print_history_item{p, Map.get(st.history, p, "IF THIS PRINTS, SOMETHING IS WRONG!")}}
    #{Map.get(st.data, p, "(no output produced??)")}
    """

  # find id'th element in list to get the port (note: humans use 1-based indexing)
  defp _id2p(list, id), do: Enum.at(list, _numeric_id(id) - 1)

  defp _numeric_id(id) do
    if String.match?(id, ~r/^\d+$/) do
      String.to_integer(id)
    else
      0
    end
  end

  defp _ts(t \\ :os.timestamp) do
    { {_, _, d}, {h, m, s} } = :calendar.now_to_local_time(t)
    :io_lib.format("~2..0B.~2..0B:~2..0B:~2..0B", [d,h,m,s]) |> List.flatten |> to_string
  end

  defp _print_history_item({pid, history}) do
    msg = """
      \tcmd:\t#{history[:cmd]}
      \tpwd:\t#{history[:pwd]}
      \tbegin:\t#{history[:begin]}
      """
    if history[:end] do
      msg = inspect(pid) <> "\n" <> msg <> """
        \tend:\t#{history[:end]}
        \texit:\t#{history[:status]}
        """
    else
      msg = "#{inspect(pid)} (#{_os_pid(pid)})" <> "\n" <> msg
    end
    msg
  end

  defp _os_pid(:undefined) do
    "exited"
  end
  defp _os_pid(info) when is_list(info) do
    info[:os_pid] |> to_string
  end
  defp _os_pid(port) do
    _os_pid Port.info(port)
  end

end
