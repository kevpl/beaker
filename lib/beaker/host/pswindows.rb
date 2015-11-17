[ 'host', 'command_factory', 'command', 'options', 'dsl/wrappers' ].each do |lib|
  require "beaker/#{lib}"
end

module PSWindows
  class Host < Windows::Host
    [ 'user', 'group', 'exec', 'pkg', 'file' ].each do |lib|
      require "beaker/host/pswindows/#{lib}"
    end

    include PSWindows::User
    include PSWindows::Group
    include PSWindows::File
    include PSWindows::Exec
    include PSWindows::Pkg

    attr_reader :scp_separator, :external_copy_base, :system_temp_path
    def initialize name, host_hash, options
      super

      @scp_separator = '/'
      # %TEMP% == C:\Users\ADMINI~1\AppData\Local\Temp
      # is a user temp path, not the system path.  Also, it doesn't work, there's
      # probably an issue with the `ADMINI~1` section
      @system_temp_path = 'C:\\Windows\\Temp'
      @external_copy_base = '/programdata'
    end

  end
end
