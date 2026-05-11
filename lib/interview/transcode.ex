defmodule Interview.Transcode do
  @moduledoc """
  ffmpeg + ffprobe helpers shared by the candidate finalizer
  (`Interview.Workers.Finalizer`) and the recruiter prompt-asset
  finalizer (`Interview.Workers.PromptAssetFinalizer`).

  Pipeline mirrors PLAN §3.3 / §12.7:

    * WebM/VP9 source → MP4 H.264 (`libx264 -preset veryfast -crf 23`).
    * `+faststart` so playback streaming works without a full download.
    * `nice -n 10` if `nice` is on the PATH — keeps ffmpeg off the web
      tier's hot scheduler.

  Returns `{:ok, dst_path}` on success or `{:error, reason}`. The caller
  owns cleanup of both the source and the produced destination.
  """

  require Logger

  @ffmpeg_args [
    "-y",
    "-i",
    :SRC,
    "-c:v",
    "libx264",
    "-preset",
    "veryfast",
    "-crf",
    "23",
    "-c:a",
    "aac",
    "-b:a",
    "128k",
    "-movflags",
    "+faststart",
    :DST
  ]

  @doc """
  Transcode `src` into a fresh MP4 in `System.tmp_dir!()`. Returns
  `{:ok, dst}` on success.
  """
  def transcode(src) when is_binary(src) do
    dst =
      Path.join(System.tmp_dir!(), "interview_transcode_#{System.unique_integer([:positive])}.mp4")

    args = Enum.map(@ffmpeg_args, &substitute(&1, src, dst))
    nice = System.find_executable("nice")
    ffmpeg = System.find_executable("ffmpeg")

    if is_nil(ffmpeg) do
      {:error, :ffmpeg_missing}
    else
      cmd_path = nice || ffmpeg
      cmd_args = if nice, do: ["-n", "10", ffmpeg | args], else: args

      case System.cmd(cmd_path, cmd_args, stderr_to_stdout: true) do
        {_out, 0} ->
          {:ok, dst}

        {out, status} ->
          File.rm(dst)
          {:error, {:ffmpeg_failed, status, String.slice(out, 0, 500)}}
      end
    end
  end

  @doc """
  Return the duration of an MP4 / WebM at `path` in milliseconds.
  Returns `{:ok, nil}` if ffprobe isn't installed (degrade gracefully).
  """
  def probe_duration_ms(path) when is_binary(path) do
    case System.find_executable("ffprobe") do
      nil ->
        {:ok, nil}

      bin ->
        args = [
          "-v",
          "error",
          "-show_entries",
          "format=duration",
          "-of",
          "default=noprint_wrappers=1:nokey=1",
          path
        ]

        case System.cmd(bin, args, stderr_to_stdout: true) do
          {out, 0} ->
            ms =
              out
              |> String.trim()
              |> Float.parse()
              |> case do
                {sec, _} -> round(sec * 1000)
                :error -> nil
              end

            {:ok, ms}

          {_out, _status} ->
            {:ok, nil}
        end
    end
  end

  defp substitute(:SRC, src, _dst), do: src
  defp substitute(:DST, _src, dst), do: dst
  defp substitute(token, _src, _dst), do: token
end
