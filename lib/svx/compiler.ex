defmodule Svx.Compiler do
  require Logger
  use GenServer

  @extensions ~w(.lsvx .svx)

  defstruct [:path, :namespace, :css_output_path, :js_output_path, :module_map]

  defmodule ParseError do
    @moduledoc false
    defexception [:file, :line, :column, :description]

    @impl true
    def message(exception) do
      location =
        exception.file
        |> Path.relative_to_cwd()
        |> format_file_line_column(exception.line, exception.column)

      "#{location} #{exception.description}"
    end

    # Use Exception.format_file_line_column/4 instead when support
    # for Elixir < v1.11 is removed.
    def format_file_line_column(file, line, column, suffix \\ "") do
      cond do
        is_nil(file) -> ""
        is_nil(line) or line == 0 -> "#{file}:#{suffix}"
        is_nil(column) or column == 0 -> "#{file}:#{line}:#{suffix}"
        true -> "#{file}:#{line}:#{column}:#{suffix}"
      end
    end
  end

  ##-------------------------------------------------------------------------##
  # GenServer
  ##-------------------------------------------------------------------------##

  def start_link(opts \\ []) do
    opts[:path] || raise ArgumentError, message: "invalid option :path"
    opts[:namespace] || raise ArgumentError, message: "invalid option :namespace"

    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  @spec init(%__MODULE__{}) :: {:ok, %__MODULE__{}}
  def init(opts) do
    assets_path = Path.absname("")
                  |> Path.join("assets")

    default_css_output_path = assets_path
                              |> Path.join("css")
                              |> Path.join("generated.css")

    default_js_output_path = assets_path
                             |> Path.join("js")
                             |> Path.join("generated.js")

    css_output_path = opts[:css_output_path] || default_css_output_path
    js_output_path = opts[:js_output_path] || default_js_output_path

    path = Path.absname(opts[:path])

    state = %__MODULE__{
      path: path,
      namespace: opts[:namespace],
      css_output_path: css_output_path,
      js_output_path: js_output_path
    }

    Logger.info("Svx starting with the following options: #{inspect state}")

    {:ok, _pid} =
      Sentix.start_link(:templates, [path], recursive: true, includes: "*.l?svx")

    Sentix.subscribe(:templates)

    module_map = compile_all(path, state)

    {
      :ok,
      state
      |> Map.put(:module_map, module_map)
    }
  end

  ##-------------------------------------------------------------------------##
  # File system events
  ##-------------------------------------------------------------------------##

  @impl true
  def handle_info({_pid, {:fswatch, :file_event}, {file_path, event_list}}, %{module_map: compiled} = state) do

    case Path.extname(file_path) in @extensions do
      true -> cond do
                :updated in event_list or :created in event_list ->
                  compiled = Map.merge(compiled, compile_many([file_path], state))
                  if css_changed?(file_path, compiled, state) do
                    Logger.info("#{Map.get(compiled, file_path).module} will update css")
                    update_css(compiled, state)
                  end
                  {:noreply, %{state | module_map: compiled}}
                :removed in event_list ->
                  # TODO: remove module
                  {:noreply, state}
              end
      false -> {:noreply, state}
    end

  end

  ##-------------------------------------------------------------------------##
  # Internal functionality
  ##-------------------------------------------------------------------------##

  def compile_all(path, state) do
    Logger.info("Recompiling all files in #{path}")
    compiled = ls_r(path)
               |> Enum.filter(fn file -> Path.extname(file) in @extensions end)
               |> Enum.chunk_every(4)
               |> Enum.map(
                    &Task.async(fn -> compile_many(&1, state) end)
                  )
               |> Task.await_many()
               |> Enum.reduce(
                    %{},
                    fn results, acc ->
                      acc
                      |> Map.merge(results)
                    end
                  )

    update_css(compiled, state)

    compiled
  end

  def compile_many(files, state) do
    files
    |> Enum.reduce(
         %{},
         fn file, acc ->
           relative_path = file
                           |> Path.relative_to(state.path)

           module_name = to_module_name(
             relative_path,
             state.namespace
           )

           Logger.info("Compiling #{module_name} (#{relative_path})")

           try do
             {:ok, content} = File.read(file)

             result = get_module(file, module_name, content, is_live?(file))

             Code.compiler_options(ignore_module_conflict: true)
             Code.compile_quoted(result.module, file)
             Code.compiler_options(ignore_module_conflict: false)

             Map.put(
               acc,
               file,
               result
               |> Map.put(:module, module_name)
             )
           rescue
             e ->
               formatted = Exception.format(:error, e, __STACKTRACE__) |> Phoenix.HTML.html_escape |> elem(1)
               Logger.error(formatted)

               module = """
                        defmodule #{module_name} do
                          use Phoenix.LiveView
                          import Phoenix.LiveView.Helpers

                          def render(assigns) do
                          ~H\"\"\"
                        <pre style=\"font-size: 1.2em; color: red; padding: 0.5em; width: 80ch; margin:auto; white-space: pre-wrap; overflow-wrap: break-word\">
                        #{formatted}
                        </pre>
                        \"\"\"
                          end
                        end
                        """
                        |> Code.string_to_quoted()
                        |> elem(1)

               Code.compiler_options(ignore_module_conflict: true)
               Code.compile_quoted(module, file)
               Code.compiler_options(ignore_module_conflict: false)

               Map.put(
                 acc,
                 file,
                 %{module: module, css: [], module_name: module_name}
               )
           end
         end
       )
  end

  defp ls_r(path) do
    cond do
      File.regular?(path) ->
        [path]

      File.dir?(path) ->
        File.ls!(path)
        |> Enum.map(&Path.join(path, &1))
        |> Enum.map(&ls_r/1)
        |> Enum.concat()

      true ->
        []
    end
  end

  defp to_module_name(path, namespace) do
    module_name =
      path
      #|> Path.relative_to("lib/")
      |> Path.rootname() # "some/path_chunks/with/file_name"
      |> Path.split() # ["some", "path_chunks", "with", "file_name"]
        # convert ["some", "path_chunks", "with", "file_name"]
        # to ["Some", "PathChunks", "With", "FileName"]
      |> Enum.map(
           fn chunk ->
             # chunk may contain underscore
             # we split them and uppercase them
             # path_chunk -> ["path", "chunk"] -> ["Path", "Chunk"] -> PathChunk
             chunk
             |> String.split("_")
             |> Enum.map(
                  fn lowercase ->
                    with <<first :: utf8, rest :: binary>> <- lowercase,
                         do: String.upcase(<<first :: utf8>>) <> rest
                  end
                )
             |> Enum.join("")
           end
         )
      |> Enum.join(".")
    "#{namespace}.#{module_name}"
  end

  defp is_live?(file), do: Path.extname(file) == ".lsvx"

  defp get_module(_file, _module_name, _content, false) do
#    module = quote do
#      defmodule unquote(module_name) do
#        require EEx
#
#        EEx.function_from_string(:def, :render, unquote(content), [:assigns], [engine: Phoenix.HTML.Engine])
#      end
#    end
#
#    %{module: module, css: ""}
    raise "Not implemented yet"
  end

  defp get_module(file, module_name, content, true) do
    parsed = collect_content(content, file)

    module = """
             defmodule #{module_name} do
               import Phoenix.LiveView.Helpers

               #{parsed.module}

               def render(assigns) do
               ~H\"\"\"
             #{parsed.content}
             \"\"\"
               end
             end
             """
             |> Code.string_to_quoted()
             |> elem(1)

    %{module: module, css: IO.iodata_to_binary(parsed.css)}
  end

  defp update_css(compiled, %{css_output_path: output_path}) do
    out = compiled
          |> Enum.reduce(
               "",
               fn ({_, %{css: css}}, acc) ->
                 case css
                      |> IO.iodata_to_binary()
                      |> String.trim() do
                   "" -> acc
                   trimmed -> acc
                              <> "\n\n"
                              <> trimmed
                 end
               end
             )

    File.write(output_path, out)
  end

  defp css_changed?(file_path, compiled, %{module_map: old_compiled}) do
    case Map.get(old_compiled, file_path) do
      nil -> true
      %{css: old_css} -> Map.get(compiled, file_path).css != old_css
    end
  end

  ##-------------------------------------------------------------------------##
  # Parse .lsvx
  ##-------------------------------------------------------------------------##

  defp collect_content(content, file) do
    {:ok, eex_regex} = Regex.compile("(<%)(.|[\r\n\s])+(%>)", [:unicode, :ungreedy])

    content = Regex.replace(
      eex_regex,
      content,
      fn full_match, _ ->
        full_match
        |> String.replace("<%", "OPENING_%_EEX")
        |> String.replace("%>", "CLOSING_%_EEX")
        |> String.replace("<", "BRACKET_%_EEX")
        |> String.replace("%{", "MAP_%_EEX")
      end
    )

    {tokens, _} = content
                  |> String.replace("<%", "OPENING_%_EEX")
                  |> String.replace("%>", "CLOSING_%_EEX")
                  |> String.replace("%{", "MAP_%_EEX")
                  |> Phoenix.LiveView.HTMLTokenizer.tokenize("", 0, [], [], :text)

    collect_tokens(
      Enum.reverse(tokens),
      %{
        module: [],
        content: [],
        css: [],
        file: file
      },
      :content
    )
  end

  defp collect_tokens([], parsed, _) do
    %{
      module: to_content(parsed.module),
      content: to_content(parsed.content),
      css: to_content(parsed.css)
    }
  end
  defp collect_tokens([token | rest], parsed, :content) do
    case token do
      {:tag_open, "script", attrs, _} ->
        case is_module_tag?(attrs) do
          true ->
            assert_not(token, :module, parsed)
            collect_tokens(rest, parsed, :module)
          false -> collect_tokens(rest, %{parsed | content: [token | parsed.content]}, :content)
        end
      {:tag_open, "style", _, _} ->
        assert_not(token, :css, parsed)
        collect_tokens(rest, parsed, :css)
      {:tag_open, _, _, _} -> collect_tokens(rest, %{parsed | content: [token | parsed.content]}, :content)
      {:tag_close, _, _} -> collect_tokens(rest, %{parsed | content: [token | parsed.content]}, :content)
      {:text, _, _} ->
        collect_tokens(rest, %{parsed | content: [token | parsed.content]}, :content)
    end
  end
  defp collect_tokens([token | rest], parsed, :module) do
    case token do
      {:tag_close, "script", _} ->
        collect_tokens(rest, parsed, :content)
      {:text, _, _} ->
        collect_tokens(rest, %{parsed | module: [token | parsed.module]}, :module)
    end
  end
  defp collect_tokens([token | rest], parsed, :css) do
    case token do
      {:tag_close, "style", _} ->
        collect_tokens(rest, parsed, :content)
      {:text, _, _} ->
        collect_tokens(rest, %{parsed | css: [token | parsed.css]}, :css)
    end
  end

  defp is_module_tag?(attrs) do
    Enum.find(attrs, fn {key, {_, value, _}} -> key == "language" and value == "elixir" end) != nil
  end

  defp to_content(lst) when is_list(lst),
       do: lst
           |> Enum.map(&to_content/1)
           |> Enum.reverse()
  defp to_content({:text, text, _}), do: restore_eex(text)
  defp to_content({:tag_open, tag, attrs, _}) do
    "<#{tag} #{attributes_to_content(attrs, [])}>"
  end
  defp to_content({:tag_close, tag, _}) do
    "</#{tag}>"
  end

  defp attributes_to_content([], acc),
       do: acc
           |> Enum.join(" ")
  defp attributes_to_content([{name, {:expr, value, _}} | rest], acc) do
    attributes_to_content(rest, ["#{name}={#{value}}" | acc])
  end
  defp attributes_to_content([{name, {_, value, meta}} | rest], acc) do
    delimiter = Map.get(meta, :delimiter, "")
    attributes_to_content(rest, ["#{name}=#{<<delimiter>>}#{value}#{<<delimiter>>}" | acc])
  end

  defp assert_not({_, _, _, meta}, what, parsed) do
    case parsed[what] do
      [] -> :ok
      _ ->
        raise ParseError,
              line: meta.line, column: meta.column, file: parsed.file, description: "Can only have one #{what} per file"
    end
  end

  defp restore_eex(text) do
    text
    |> String.replace("OPENING_%_EEX", "<%")
    |> String.replace("CLOSING_%_EEX", "%>")
    |> String.replace("BRACKET_%_EEX", "<")
    |> String.replace("MAP_%_EEX", "%{")
  end

end