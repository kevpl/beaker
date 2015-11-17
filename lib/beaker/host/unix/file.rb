module Unix::File
  include Beaker::CommandFactory

  def tmpfile(name)
    execute("mktemp -t #{name}.XXXXXX")
  end

  def tmpdir(name)
    execute("mktemp -dt #{name}.XXXXXX")
  end

  def system_temp_path
    msg = "unix/file.rb: system_temp_path: Only available on Windows hosts"
    raise NotImplementedError msg
  end

  # Handles any changes needed in a path for SCP
  #
  # @note This is really only needed in Windows at this point. Refer to
  #   {Windows::File#scp_path} for more info
  def scp_path path
    path
  end

  def path_split(paths)
    paths.split(':')
  end

  def file_exist?(path)
    result = exec(Beaker::Command.new("test -e #{path}"), :acceptable_exit_codes => [0, 1])
    result.exit_code == 0
  end
end
