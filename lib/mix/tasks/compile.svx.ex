defmodule Mix.Tasks.Compile.Svx do
  require Logger
  use Mix.Task
  @recursive true

  def run(args) do
    Code.ensure_compiled(Svx.Compiler)

    Logger.info("Compiling Svx single-file components")

    templates = Path.join("lib/**", "/*.*svx")
                |> Path.wildcard()
    results = Svx.Compiler.compile_and_reload(templates)

    assets_path = Path.absname("")
                  |> Path.join("assets")
                  |> Path.join("css")
                  |> Path.join("generated.css")

    results
    |> Enum.reduce(
         "",
         fn {module, %{css: css}}, acc ->
           "#{acc}/* --- #{module} --- */\n#{css}\n\n"
         end
       )
    |> (&File.write(assets_path, &1)).()
    :ok
  end
end