defmodule Mix.Tasks.Sagents.Gen.LiveHelpers do
  @shortdoc "Generates AgentLiveHelpers module for Phoenix LiveView integration"

  @moduledoc """
  Generates AgentLiveHelpers module for Phoenix LiveView integration with Sagents.

  This module provides reusable patterns for agent event handling, state persistence,
  and UI updates in Phoenix LiveView applications. All functions take a socket and
  return an updated socket, following the LiveView pattern.

  ## Examples

      # Basic generation
      mix sagents.gen.live_helpers MyAppWeb.AgentLiveHelpers \\
        --context MyApp.Conversations

      # With all options
      mix sagents.gen.live_helpers MyAppWeb.AgentLiveHelpers \\
        --context MyApp.Conversations \\
        --test-path test/my_app_web/live

  ## Generated files

    * **Helper module**: Reusable handlers for agent events (status, messages, tools, lifecycle)
    * **Test file**: Comprehensive test suite with socket mocking

  ## Options

    * `--context` - Your conversations context module (required, e.g., MyApp.Conversations)
    * `--test-path` - Test file directory (default: inferred from helper module path)
    * `--no-test` - Skip generating test file

  ## Integration

  After generation, use the helpers in your LiveView handlers:

      @impl true
      def handle_info({:agent, {:status_changed, :running, nil}}, socket) do
        {:noreply, AgentLiveHelpers.handle_status_running(socket)}
      end

  See the generated file for complete documentation and usage examples.
  """

  use Mix.Task

  @switches [
    context: :string,
    test_path: :string,
    no_test: :boolean
  ]

  @aliases [
    c: :context
  ]

  @impl Mix.Task
  def run(args) do
    # Parse arguments
    {opts, parsed, _} = OptionParser.parse(args, switches: @switches, aliases: @aliases)

    # Validate helper module argument
    helper_module = parse_helper_module!(parsed)

    # Validate context option
    context_module = parse_context!(opts)

    # Build configuration
    config = build_config(helper_module, context_module, opts)

    # Check for existing files before generating
    check_existing_files!(config)

    # Generate files
    generated_files = generate_files(config)

    # Print all generated files
    print_generated_files(generated_files)

    # Print instructions
    print_instructions(config)
  end

  defp parse_helper_module!([helper_module | _]) do
    # Validate module name format
    unless helper_module =~ ~r/^[A-Z][A-Za-z0-9.]*$/ do
      Mix.raise("Helper module must be a valid Elixir module name")
    end

    # Validate that the module is in the Web namespace (Phoenix convention)
    unless String.contains?(helper_module, "Web") do
      base_module = helper_module |> String.split(".") |> hd()

      Mix.raise("""
      Helper module must be in the Web namespace for Phoenix LiveView.

      You provided: #{helper_module}
      Did you mean: #{base_module}Web.AgentLiveHelpers?

      LiveView helpers should always be under your application's Web module.
      Example: mix sagents.gen.live_helpers MyAppWeb.AgentLiveHelpers --context MyApp.Conversations
      """)
    end

    helper_module
  end

  defp parse_helper_module!([]) do
    Mix.raise(
      "Helper module is required. Example: mix sagents.gen.live_helpers MyAppWeb.AgentLiveHelpers --context MyApp.Conversations"
    )
  end

  defp parse_context!(opts) do
    case opts[:context] do
      nil ->
        Mix.raise(
          "Context module is required. Use --context flag. Example: --context MyApp.Conversations"
        )

      context_module ->
        # Validate module name format
        unless context_module =~ ~r/^[A-Z][A-Za-z0-9.]*$/ do
          Mix.raise("Context module must be a valid Elixir module name")
        end

        context_module
    end
  end

  defp build_config(helper_module, context_module, opts) do
    # Infer application from helper module
    app = infer_app(helper_module)

    %{
      helper_module: helper_module,
      context_module: context_module,
      app: app,
      app_module: app_module(app),
      test_path: opts[:test_path] || infer_test_path(helper_module),
      generate_test: !opts[:no_test]
    }
  end

  defp check_existing_files!(config) do
    # Get list of all files that will be generated
    files_to_generate = [module_to_path(config.helper_module)]

    files_to_generate =
      if config.generate_test do
        [test_module_to_path(config.helper_module, config.test_path) | files_to_generate]
      else
        files_to_generate
      end

    # Check which files already exist
    existing_files = Enum.filter(files_to_generate, &File.exists?/1)

    if Enum.any?(existing_files) do
      Mix.shell().info(
        "\n#{IO.ANSI.yellow()}Warning: The following files already exist:#{IO.ANSI.reset()}\n"
      )

      Enum.each(existing_files, fn file ->
        Mix.shell().info("  * #{IO.ANSI.red()}#{file}#{IO.ANSI.reset()}")
      end)

      Mix.shell().info("")

      response =
        Mix.shell().yes?(
          "Do you want to overwrite these files? This cannot be undone unless you have them in git."
        )

      unless response do
        Mix.shell().info(
          "\n#{IO.ANSI.yellow()}Aborted. No files were modified.#{IO.ANSI.reset()}"
        )

        System.halt(0)
      end

      Mix.shell().info("")
    end
  end

  defp generate_files(config) do
    files = []

    # Generate helper module
    helper_file = generate_helper_module(config)
    files = [helper_file | files]

    # Generate test file if requested
    files =
      if config.generate_test do
        test_file = generate_test_file(config)
        [test_file | files]
      else
        files
      end

    Enum.reverse(files)
  end

  defp generate_helper_module(config) do
    # Extract short alias for conversations module (e.g., Conversations from AgentsDemo.Conversations)
    conversations_alias =
      config.context_module
      |> String.split(".")
      |> List.last()

    # Prepare bindings for helper template
    binding = [
      module: config.helper_module,
      conversations_module: config.context_module,
      conversations_alias: conversations_alias,
      app: config.app
    ]

    # Load and evaluate template
    template_path = Application.app_dir(:sagents, "priv/templates/agent_live_helpers.ex.eex")
    content = EEx.eval_file(template_path, binding)

    # Write file
    helper_path = module_to_path(config.helper_module)
    File.mkdir_p!(Path.dirname(helper_path))
    File.write!(helper_path, content)

    helper_path
  end

  defp generate_test_file(config) do
    # Extract test module name from helper module
    test_module = "#{config.helper_module}Test"

    # Extract short alias name (e.g., AgentLiveHelpers from AgentsDemoWeb.AgentLiveHelpers)
    helper_alias =
      config.helper_module
      |> String.split(".")
      |> List.last()

    # Extract short alias for conversations module (e.g., Conversations from AgentsDemo.Conversations)
    conversations_alias =
      config.context_module
      |> String.split(".")
      |> List.last()

    # Prepare bindings for test template
    binding = [
      module: test_module,
      helper_module: config.helper_module,
      helper_alias: helper_alias,
      conversations_module: config.context_module,
      conversations_alias: conversations_alias,
      app: config.app,
      app_web_module: infer_web_module(config.helper_module)
    ]

    # Load and evaluate template
    template_path =
      Application.app_dir(:sagents, "priv/templates/agent_live_helpers_test.exs.eex")

    content = EEx.eval_file(template_path, binding)

    # Write file
    test_path = test_module_to_path(config.helper_module, config.test_path)
    File.mkdir_p!(Path.dirname(test_path))
    File.write!(test_path, content)

    test_path
  end

  defp print_generated_files(files) do
    Mix.shell().info("\nGenerated files:")

    Enum.each(files, fn file ->
      Mix.shell().info("  * #{IO.ANSI.green()}#{file}#{IO.ANSI.reset()}")
    end)
  end

  defp print_instructions(config) do
    helper_path = module_to_path(config.helper_module)

    Mix.shell().info([
      :green,
      """

      🎉 AgentLiveHelpers generated successfully!

      Next steps:

        1. Review the generated helper module (#{helper_path}):
           * All handler functions are ready to use
           * Customize message formatting or error handling as needed
           * The module is hardcoded with your context (#{config.context_module})

        2. Integrate into your LiveView handlers:

           defmodule MyAppWeb.ChatLive do
             alias #{config.helper_module}

             @impl true
             def handle_info({:agent, {:status_changed, :running, nil}}, socket) do
               {:noreply, AgentLiveHelpers.handle_status_running(socket)}
             end

             @impl true
             def handle_info({:agent, {:status_changed, :idle, _data}}, socket) do
               {:noreply, AgentLiveHelpers.handle_status_idle(socket)}
             end

             @impl true
             def handle_info({:agent, {:status_changed, :cancelled, _data}}, socket) do
               {:noreply, AgentLiveHelpers.handle_status_cancelled(socket)}
             end

             @impl true
             def handle_info({:agent, {:status_changed, :error, reason}}, socket) do
               {:noreply,
                socket
                |> AgentLiveHelpers.handle_status_error(reason)
                |> push_event("scroll-to-bottom", %{})}
             end

             @impl true
             def handle_info({:agent, {:llm_deltas, deltas}}, socket) do
               {:noreply, AgentLiveHelpers.handle_llm_deltas(socket, deltas)}
             end

             # ... other handlers
           end

        3. Run tests to verify everything works:

           mix test #{if config.generate_test, do: test_module_to_path(config.helper_module, config.test_path), else: ""}

      Key features of the generated helpers:
        - Status change handlers (running, idle, cancelled, error, interrupted)
        - Message handlers (LLM deltas, message complete, display messages)
        - Tool execution handlers (identified, started, completed, failed)
        - Lifecycle handlers (title generated, agent shutdown)
        - Core helper functions (persist state, reload messages, create messages)

      See the generated file for complete documentation and all available functions.

      """
    ])
  end

  # Helper functions

  defp infer_app(module) do
    module
    |> String.split(".")
    |> hd()
    |> Macro.underscore()
    |> String.to_atom()
  end

  defp app_module(app) do
    app
    |> Atom.to_string()
    |> Macro.camelize()
  end

  defp infer_web_module(helper_module) do
    # Extract web module from helper module
    # e.g., MyAppWeb.AgentLiveHelpers -> MyAppWeb
    # e.g., AgentsDemoWeb.AgentLiveHelpers -> AgentsDemoWeb
    helper_module
    |> String.split(".")
    |> hd()
  end

  defp infer_test_path(helper_module) do
    # Convert module to test path
    # MyAppWeb.AgentLiveHelpers -> test/my_app_web/live
    # AgentsDemoWeb.AgentLiveHelpers -> test/agents_demo_web/live
    parts = String.split(helper_module, ".")
    {web_parts, _helper_name} = Enum.split(parts, -1)

    web_path = web_parts |> Enum.map(&Macro.underscore/1) |> Path.join()
    Path.join(["test", web_path, "live"])
  end

  defp module_to_path(module) when is_binary(module) do
    # Convert MyAppWeb.AgentLiveHelpers to lib/my_app_web/live/agent_live_helpers.ex
    parts = String.split(module, ".")

    # Get the web module parts (e.g., ["MyAppWeb"]) and the helper name (e.g., "AgentLiveHelpers")
    {web_parts, [helper_name]} = Enum.split(parts, -1)

    # Convert to path: my_app_web/live/agent_live_helpers
    web_path = web_parts |> Enum.map(&Macro.underscore/1) |> Path.join()
    helper_file = Macro.underscore(helper_name) <> ".ex"

    Path.join(["lib", web_path, "live", helper_file])
  end

  defp test_module_to_path(module, test_path) when is_binary(module) do
    # Get just the last part of the module name
    module_name =
      module
      |> String.split(".")
      |> List.last()
      |> Macro.underscore()

    Path.join(test_path, "#{module_name}_test.exs")
  end
end
