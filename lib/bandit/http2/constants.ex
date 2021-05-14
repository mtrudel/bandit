defmodule Bandit.HTTP2.Constants do
  @moduledoc """
  Constants as defined in RFC7540§11
  """

  def no_error, do: 0x0
  def protocol_error, do: 0x1
  def internal_error, do: 0x2
  def flow_control_error, do: 0x3
  def settings_timeout, do: 0x4
  def stream_closed, do: 0x5
  def frame_size_error, do: 0x6
  def refused_stream, do: 0x7
  def cancel, do: 0x8
  def compression_error, do: 0x9
  def connect_error, do: 0xA
  def enhance_your_calm, do: 0xB
  def inadequate_security, do: 0xC
  def http_1_1_requires, do: 0xD
end
