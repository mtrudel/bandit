defmodule Bandit.HTTP2.Errors do
  @moduledoc """
  Errors as defined in RFC7540§11
  """

  @typedoc "An error code as defined for GOAWAY and RST_STREAM errors"
  @type error_code() :: non_neg_integer()

  @spec no_error() :: error_code()
  def no_error, do: 0x0

  @spec protocol_error() :: error_code()
  def protocol_error, do: 0x1

  @spec internal_error() :: error_code()
  def internal_error, do: 0x2

  @spec flow_control_error() :: error_code()
  def flow_control_error, do: 0x3

  @spec settings_timeout() :: error_code()
  def settings_timeout, do: 0x4

  @spec stream_closed() :: error_code()
  def stream_closed, do: 0x5

  @spec frame_size_error() :: error_code()
  def frame_size_error, do: 0x6

  @spec refused_stream() :: error_code()
  def refused_stream, do: 0x7

  @spec cancel() :: error_code()
  def cancel, do: 0x8

  @spec compression_error() :: error_code()
  def compression_error, do: 0x9

  @spec connect_error() :: error_code()
  def connect_error, do: 0xA

  @spec enhance_your_calm() :: error_code()
  def enhance_your_calm, do: 0xB

  @spec inadequate_security() :: error_code()
  def inadequate_security, do: 0xC

  @spec http_1_1_requires() :: error_code()
  def http_1_1_requires, do: 0xD
end
