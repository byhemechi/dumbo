defmodule Dumbo.MixProject do
  use Mix.Project

  def project do
    [
      app: :dumbo,
      version: "0.2.0",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps(),

      # Docs
      name: "Dumbo",
      source_url: "https://github.com/byhemechi/dumbo",
      docs: docs(),
      package: package(),
      description: "PHP serialisation format support for Elixir"
    ]
  end

  defp docs do
    [
      main: "Dumbo",
      logo: "elephant.svg",
      extras: []
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:ex_doc, "~> 0.34", only: :dev, runtime: false, warn_if_outdated: true}
    ]
  end

  defp package() do
    [
      licenses: ["Apache-2.0"],
      links: %{"GitHub" => "https://github.com/byhemechi/dumbo"}
    ]
  end
end
