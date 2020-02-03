defmodule ConcurrentLimitsTest do
  use ExUnit.Case, async: false
  doctest ConcurrentLimits

  setup do
    Application.put_env(:concurrent_limits, :default_limit, 4)
    {:ok, pid} = ConcurrentLimits.start_link()

    on_exit(fn ->
      ConcurrentLimits.stop()
      assert_down(pid)
    end)
    :ok
  end

  test "given functions are executed eventually" do
    {fun, ref} = make_fun(0)
    assert {:ok, ^ref} = ConcurrentLimits.run(:exe, fun)
    assert_receive {:starting, ^ref}
    assert_receive {:stopping, ^ref}
  end

  test "a lot of functions are executed eventually" do
    num = 500
    Enum.each(1..num, fn _ ->
      Task.start_link(fn ->
        {fun, ref} = make_fun(50)
        assert {:ok, ^ref} = ConcurrentLimits.run(:execute, fun, queue_timeout: :infinity)
        assert_receive {:starting, ^ref}
        assert_receive {:stopping, ^ref}
      end)
    end)
  end

  test "returns error when queue takes too long to clear" do
    Application.put_env(:concurrent_limits, :default_limit, 1)
    {fun, blocking_ref} = make_fun(90)
    Task.start(fn ->
      assert {:ok, ^blocking_ref} = ConcurrentLimits.run(:exe, fun)
    end)
    assert_receive {:starting, ^blocking_ref}

    {fun, _ref} = make_fun(1000)
    assert {:error, :queue_timeout} = ConcurrentLimits.run(:exe, fun, queue_timeout: 5)

    assert_receive {:stopping, ^blocking_ref}
  end

  test "queue is worked in-order" do
    funs = Enum.map(1..5, fn _ -> make_fun(0) end)
    Enum.each(funs, fn {fun, ref} ->
      Task.start_link(fn ->
        assert {:ok, ^ref} = ConcurrentLimits.run(:execute, fun)
      end)
    end)
    Enum.each(funs, fn {_fun, ref} ->
      assert_receive {:starting, ^ref}
      assert_receive {:stopping, ^ref}
    end)
  end

  defp make_fun(ref \\ make_ref(), sleep) do
    pid = self()
    fun = fn ->
      send(pid, {:starting, ref})
      if not is_nil(sleep) and sleep > 0 do
        Process.sleep(sleep)
      end
      send(pid, {:stopping, ref})
      {:ok, ref}
    end
    {fun, ref}
  end

  # thank you jose
  # https://elixirforum.com/t/how-to-stop-otp-processes-started-in-exunit-setup-callback/3794/5
  defp assert_down(pid) do
    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, _, _, _}
  end
end
