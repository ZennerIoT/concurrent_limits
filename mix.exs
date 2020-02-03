defmodule ConcurrentLimits.MixProject do
  use Mix.Project

  def project do
    [
      app: :concurrent_limits,
      version: "0.1.0",
      elixir: "~> 1.9",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      package: [
        description: "Limit how many of the same function can execute simultaneously",
        licenses: ["MIT"],
        links: %{"GitHub" => "https://github.com/ZennerIoT/concurrent_limits"}
      ]
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:maracuja, "~> 0.2.0"},
      {:ex_doc, "~> 0.21", only: :dev, runtime: false}
    ]
  end
end
