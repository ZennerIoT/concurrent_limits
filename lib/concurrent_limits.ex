defmodule ConcurrentLimits do
  @type category :: atom
  @type item :: {reference, category, GenServer.from}

  @doc """
  Returns the maximum amount of concurrent instances for the given category.

  The limits can be configured in your `config.exs`:

      config :concurrent_limits,
        categories: [sleep: 8, calculate: 2],
        default_limit: 2
  """
  @spec limit_for_category(category) :: non_neg_integer
  def limit_for_category(category) do
    categories = Application.get_env(:concurrent_limits, :categories, [])
    default_limit = Application.get_env(:concurrent_limits, :default_limit, 4)
    Keyword.get(categories, category, default_limit)
  end

  @doc """
  Waits until a slot is available for the given `category` and then calls `fun`.

  This function will block until a slot is available (or acquiring one times out)
  and the given `fun` is executed.

  The `fun` will be called from the process `run/3` was called from, so it can be
  used in transactions.

  The return value will be decided as follows:

   * if we had to wait longer than `queue_timeout` (default 5000) ms for a spot,
     `{:error, :queue_timeout}`
   * if `fun.()` returned an ok- or error-tuple, its return value is returned as is
   * otherwise, the return value is wrapped into an ok-tuple

  ### Options

   * `:queue_timeout` (default `5_000`) max time to wait for a slot, in ms.
  """
  @spec run(category, fun :: (()->any), keyword) :: {:ok, any} | {:error, :queue_timeout} | {:error, any}
  def run(category, fun, opts \\ []) do
    queue_timeout = Keyword.get(opts, :queue_timeout, 5_000)
    ref = make_ref()
    try do
      :execute = GenServer.call(pid(), {:wait_for_slot, ref, category}, queue_timeout)
      res = fun.()
      case res do
        {:ok, _} -> res
        {:error, _} -> res
        o -> {:ok, o}
      end
    catch
      # be super specific about this match, so exits that come from the fun are bubbled up
      :exit, {:timeout, {GenServer, :call, [_, {:wait_for_slot, _, _}, _]}} ->
        {:error, :queue_timeout}
    after
      GenServer.cast(pid(), {:give_up_slot, ref})
    end
  end

  def stop() do
    GenServer.cast(pid(), :stop)
  end

  @doc """
  Returns the current state.

      %ConcurrentLimits.State{
        running: [], # list of items
        queue: [] # list of items
      }
  """
  def state() do
    GenServer.call(pid(), :state)
  end

  defp pid() do
    :global.whereis_name(__MODULE__)
  end

  use GenServer

  @spec start_link :: :ignore | {:error, any} | {:ok, pid}
  def start_link() do
    Maracuja.start_link(__MODULE__, [], __MODULE__)
  end

  def start_server(args, name) do
    GenServer.start_link(__MODULE__, args, [name: name])
  end

  defmodule State do
    defstruct [queue: [], running: []]
  end

  alias __MODULE__.State

  def init(_) do
    {:ok, %State{}}
  end

  def handle_call({:wait_for_slot, ref, category}, from, state) do
    {:noreply, add_slot(state, ref, category, from)}
  end

  def handle_call(:state, _from, state) do
    {:reply, state, state}
  end

  def handle_cast({:give_up_slot, ref}, state) do
    {:noreply, clear_slot(state, ref)}
  end

  def handle_cast(:stop, state) do
    {:stop, :normal, state}
  end

  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    {:noreply, clear_slots_of_pid(state, pid)}
  end

  defp add_slot(state, ref, category, {pid, _} = from) do
    Process.monitor(pid)
    item = {ref, category, from}
    %{ state | queue: state.queue ++ [item] } |> take_next(category)
  end

  defp clear_slot(state, ref) do
    queue_index = Enum.find_index(state.queue, fn {oref, _category, _from} -> oref == ref end)
    running_index = Enum.find_index(state.running, fn {oref, _category, _from} -> oref == ref end)
    case {queue_index, running_index} do
      {nil, nil} ->
        state

      {nil, index} ->
        {{_ref, category, _from}, running} = List.pop_at(state.running, index)
        %{ state | running: running } |> take_next(category)

      {index, nil} ->
        {{_ref, category, _from}, queue} = List.pop_at(state.queue, index)
        %{ state | queue: queue } |> take_next(category)
    end
  end

  # when a process that's waiting for slots crashes, clear all its slots
  defp clear_slots_of_pid(state, pid) do
    items = Enum.filter(state.queue ++ state.running, pid_filter(pid))
    Enum.reduce(items, state, fn {ref, _category, _from}, state ->
      clear_slot(state, ref)
    end)
  end

  # if a slot is available in the given category, gives that
  # slot to the first queued item of this category
  defp take_next(state, category) do
    limit = limit_for_category(category)
    running = Enum.count(state.running, category_filter(category))
    if running < limit do
      case Enum.find_index(state.queue, category_filter(category)) do
        nil ->
          state

        index ->
          {{_ref, _category, from} = item, queue} = List.pop_at(state.queue, index)
          GenServer.reply(from, :execute)
          %{ state | queue: queue, running: state.running ++ [item]}
      end
    else
      state
    end
  end

  defp category_filter(category) do
    fn {_ref, ocategory, _from} -> ocategory == category end
  end

  defp pid_filter(pid) do
    fn {_ref, _category, {opid, _from_ref} = _from} -> opid == pid end
  end
end
