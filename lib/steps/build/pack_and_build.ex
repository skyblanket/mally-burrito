defmodule Burrito.Steps.Build.PackAndBuild do
  alias Burrito.Builder.Context
  alias Burrito.Builder.Log
  alias Burrito.Builder.Step
  alias Burrito.Builder.Target

  @behaviour Step

  @impl Step
  def execute(%Context{} = context) do
    options = context.mix_release.options[:burrito] || []
    release_name = Atom.to_string(context.mix_release.name)
    build_triplet = Target.make_triplet(context.target)

    plugin_path = maybe_get_plugin_path(options[:plugin])

    zig_build_args = ["-Dtarget=#{build_triplet}"]

    create_metadata_file(context.self_dir, context.mix_release)

    # Touch a file inside lib to work around a Linux container FS bug
    Path.join(context.work_dir, ["/lib", "/.mrt"]) |> File.touch!()

    build_env =
      [
        {"__MRT_IS_PROD", is_prod(context.target)},
        {"__MRT_RELEASE_PATH", context.work_dir},
        {"__MRT_RELEASE_NAME", release_name},
        {"__MRT_PLUGIN_PATH", plugin_path}
      ] ++ context.extra_build_env

    Log.info(:step, "Build env: #{inspect(build_env)}")

    build_result =
      System.cmd("zig", ["build"] ++ zig_build_args,
        cd: context.self_dir,
        env: build_env,
        into: IO.stream()
      )

    if !options[:no_clean] do
      clean_build(context.self_dir)
    end

    case build_result do
      {_, 0} ->
        context

      _ ->
        Log.error(:step, "Build failed! Check the logs for more information.")
        raise "Wrapper build failed"
    end
  end

  defp maybe_get_plugin_path(nil), do: nil

  defp maybe_get_plugin_path(plugin_path) do
    Path.join(File.cwd!(), [plugin_path])
  end

  defp create_metadata_file(self_path, release) do
    app_version = release.version
    erts_version = release.erts_version |> to_string()

    # Binary format: [u8 app_version_len][app_version][u8 erts_version_len][erts_version]
    binary = <<
      byte_size(app_version)::8,
      app_version::binary,
      byte_size(erts_version)::8,
      erts_version::binary
    >>

    Path.join(self_path, ["src/", "_metadata.bin"]) |> File.write!(binary)
  end

  defp is_prod(%Target{debug?: debug?}) do
    cond do
      debug? -> "0"
      Mix.env() == :prod -> "1"
      true -> "0"
    end
  end

  defp clean_build(self_path) do
    cache = Path.join(self_path, "zig-cache")
    out = Path.join(self_path, "zig-out")
    payload = Path.join(self_path, "payload.foilz")
    compressed_payload = Path.join(self_path, ["src/", "payload.foilz.xz"])
    musl_runtime = Path.join(self_path, ["src/", "musl-runtime.so"])
    metadata = Path.join(self_path, ["src/", "_metadata.bin"])

    File.rmdir(cache)
    File.rmdir(out)
    File.rm(payload)
    File.rm(compressed_payload)
    File.rm(musl_runtime)
    File.rm(metadata)

    :ok
  end
end
