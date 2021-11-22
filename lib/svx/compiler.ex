defmodule Svx.Compiler do
  require Logger

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


  def compile_and_reload(files) do
    Code.compiler_options(ignore_module_conflict: true)

    app_name = Mix.Project.config()[:app]

    prelude = case Application.fetch_env(app_name, :svx) do
      :error -> []
      {:ok, list} -> Keyword.get(list, :prelude, [])
    end


    modules = for template_with_path <- files do
      module_name = module_name_from_path(template_with_path)

      Logger.info("Compiling #{module_name} (#{template_with_path})")

      {:ok, content} = File.read(template_with_path)

      parsed = collect_content(content, template_with_path)

      module = """
      defmodule #{module_name} do
        #{
          prelude
          |> Enum.join("\n")
        }

        #{parsed.module}

        def render(assigns) do
        ~H\"\"\"
      #{parsed.content}
      \"\"\"
        end
      end
      """
      Code.compile_string(module, template_with_path)
      {module_name, parsed}
    end

    Code.compiler_options(ignore_module_conflict: false)
    modules
  end

  defp module_name_from_path(path) do
    module_name = path
                  |> Path.relative_to("lib/")
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
                  |> Enum.join(".") # Some.PathChunk.With.Filename

    module_name
  end

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