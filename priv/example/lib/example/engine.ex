defmodule Svx.Engine do
  def compile(template_path, template_name) do
    #{:safe, File.read!(template_path) |> compile_string(template_path)}
    IO.inspect({:COMPILE, template_path, template_name})
  end

  def compile_string(string, file) do
    IO.inspect({:COMPILE_STRING, string, file})
#    string
#    |> Svx.Compiler.compile(file: file)
  end

end