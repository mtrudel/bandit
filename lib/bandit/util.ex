defmodule Bandit.Util do
  @moduledoc false

  def labels_supported? do
    function_exported?(:proc_lib, :get_label, 1) and function_exported?(:proc_lib, :set_label, 1)
  end

  def get_label(pid) do
    if function_exported?(:proc_lib, :get_label, 1) do
      # `apply/3` avoids a compiler warning when OTP doesn't support this
      # credo:disable-for-next-line
      apply(:proc_lib, :get_label, [pid])
    else
      :undefined
    end
  end

  def set_label(label) do
    if function_exported?(:proc_lib, :set_label, 1) do
      # `apply/3` avoids a compiler warning when OTP doesn't support this
      # credo:disable-for-next-line
      apply(:proc_lib, :set_label, [label])
    else
      :ok
    end
  end
end
