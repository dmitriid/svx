defmodule Svx.MixProject do
  use Mix.Project

  def project do
    [
      app: :svx,
      name: "Svx",
      version: "0.2.0",
      description: "A PoC for single-file components for Phoenix LiveView",
      elixir: "~> 1.12",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      package: package(),
      source_url: "https://github.com/dmitriid/svx",
      homepage_url: "https://github.com/dmitriid/svx",
      docs: [
        main: "readme", # The main page in the docs
        extras: ["README.md"]
      ]
    ]
  end

  defp deps do
    [
      {:phoenix, "~> 1.6.2", runtime: true},
      {:phoenix_html, "~> 3.0", runtime: true},
      {:phoenix_live_view, "~> 0.17.5", runtime: true},
      {:ex_doc, "~> 0.25", only: :dev, runtime: false}
    ]
  end

  def package() do
    [
      licenses: ["MPL-2.0"],
      links: %{
        "GitHub" => "https://github.com/dmitriid/svx"
      }
    ]
  end
end
