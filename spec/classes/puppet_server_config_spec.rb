require 'spec_helper'

describe 'puppet::server::config' do
  on_supported_os.each do |os, os_facts|
    next if only_test_os() and not only_test_os.include?(os)
    next if exclude_test_os() and exclude_test_os.include?(os)
    next if os_facts[:osfamily] == 'windows'
    context "on #{os}" do
      let (:default_facts) do
        os_facts.merge({
          :clientcert             => 'puppetmaster.example.com',
          :concat_basedir         => '/nonexistant',
          :fqdn                   => 'puppetmaster.example.com',
          :puppetversion          => Puppet.version,
      }) end

      if Puppet.version < '4.0'
        codedir             = '/etc/puppet'
        confdir             = '/etc/puppet'
        conf_file           = '/etc/puppet/puppet.conf'
        environments_dir    = '/etc/puppet/environments'
        logdir              = '/var/log/puppet'
        rundir              = '/var/run/puppet'
        vardir              = '/var/lib/puppet'
        puppetserver_vardir = '/var/lib/puppet'
        ssldir              = '/var/lib/puppet/ssl'
        sharedir            = '/usr/share/puppet'
        etcdir              = '/etc/puppet'
        puppetcacmd         = '/usr/bin/puppet cert'
        additional_facts    = {}
      else
        codedir             = '/etc/puppetlabs/code'
        confdir             = '/etc/puppetlabs/puppet'
        conf_file           = '/etc/puppetlabs/puppet/puppet.conf'
        environments_dir    = '/etc/puppetlabs/code/environments'
        logdir              = '/var/log/puppetlabs/puppet'
        rundir              = '/var/run/puppetlabs'
        vardir              = '/opt/puppetlabs/puppet/cache'
        puppetserver_vardir = '/opt/puppetlabs/server/data/puppetserver'
        ssldir              = '/etc/puppetlabs/puppet/ssl'
        sharedir            = '/opt/puppetlabs/puppet'
        etcdir              = '/etc/puppetlabs/puppet'
        puppetcacmd         = '/opt/puppetlabs/bin/puppet cert'
        additional_facts    = {:rubysitedir => '/opt/puppetlabs/puppet/lib/ruby/site_ruby/2.1.0'}
      end

      if os_facts[:osfamily] == 'FreeBSD'
        codedir             = '/usr/local/etc/puppet'
        confdir             = '/usr/local/etc/puppet'
        conf_file           = '/usr/local/etc/puppet/puppet.conf'
        environments_dir    = '/usr/local/etc/puppet/environments'
        logdir              = '/var/log/puppet'
        rundir              = '/var/run/puppet'
        vardir              = '/var/puppet'
        puppetserver_vardir = '/var/puppet'
        ssldir              = '/var/puppet/ssl'
        sharedir            = '/usr/local/share/puppet'
        etcdir              = '/usr/local/etc/puppet'
        puppetcacmd         = '/usr/local/bin/puppet cert'
        additional_facts    = {}
      end

      let(:facts) { default_facts.merge(additional_facts) }

      describe 'with no custom parameters' do
        let :pre_condition do
          "class {'puppet': server => true}"
        end

        it 'should set up SSL permissions' do
          should contain_file("#{ssldir}/private_keys").with({
            :group => 'puppet',
            :mode  => '0750',
          })

          should contain_file("#{ssldir}/private_keys/puppetmaster.example.com.pem").with({
            :group => 'puppet',
            :mode  => '0640',
          })

          should contain_exec('puppet_server_config-create_ssl_dir').with({
            :creates => ssldir,
            :command => "/bin/mkdir -p #{ssldir}",
          })

          should contain_exec('puppet_server_config-generate_ca_cert').with({
            :creates => "#{ssldir}/certs/puppetmaster.example.com.pem",
            :command => "#{puppetcacmd} --generate puppetmaster.example.com",
            :require => ["Concat[#{conf_file}]", "Exec[puppet_server_config-create_ssl_dir]"],
          })
        end

        context 'with non-AIO packages', :if => (Puppet.version < '4.0' || os_facts[:osfamily] == 'FreeBSD') do
          it 'CA cert generation should notify the Apache service' do
            should contain_exec('puppet_server_config-generate_ca_cert').that_notifies('Service[httpd]')
          end
        end

        context 'with AIO packages', :if => (Puppet.version > '4.0' && os_facts[:osfamily] != 'FreeBSD') do
          it 'CA cert generation should notify the puppetserver service' do
            should contain_exec('puppet_server_config-generate_ca_cert').that_notifies('Service[puppetserver]')
          end
        end

        context 'on Puppet 3.4+', :if => (Puppet.version >= '3.4.0') do
          it 'should set sane umask on execs' do
            should contain_exec('puppet_server_config-create_ssl_dir').with_umask('0022')
            should contain_exec('puppet_server_config-generate_ca_cert').with_umask('0022')
          end
        end

        it 'should set up the ENC' do
          should contain_class('foreman::puppetmaster').with({
            :foreman_url    => "https://puppetmaster.example.com",
            :receive_facts  => true,
            :puppet_home    => puppetserver_vardir,
            :puppet_etcdir  => etcdir,
            # Since this is managed inside the foreman module it does not
            # make sense to test it here
            #:puppet_basedir => '/usr/lib/ruby/site_ruby/1.9/puppet',
            :timeout        => 60,
          })
        end

        it 'should set up the environments' do
          should contain_file(environments_dir).with({
            :ensure => 'directory',
            :owner => 'puppet',
            :group => nil,
            :mode => '0755',
          })
          should contain_file(sharedir).with_ensure('directory')
          should contain_file("#{codedir}/environments/common").with({
            :ensure => 'directory',
            :owner => 'puppet',
            :group => nil,
            :mode => '0755',
          })

          should contain_file("#{sharedir}/modules").with({
            :ensure => 'directory',
            :owner => 'puppet',
            :group => nil,
            :mode => '0755',
          })

          should contain_puppet__server__env('development')
          should contain_puppet__server__env('production')

        end

        it 'should configure puppet' do
          should contain_concat__fragment('puppet.conf+10-main').
            with_content(/^\s+logdir\s+= #{logdir}$/).
            with_content(/^\s+rundir\s+= #{rundir}$/).
            with_content(/^\s+ssldir\s+= #{ssldir}$/).
            with_content(/^\s+privatekeydir\s+= \$ssldir\/private_keys \{ group = service \}$/).
            with_content(/^\s+hostprivkey\s+= \$privatekeydir\/\$certname.pem \{ mode = 640 \}$/).
            with({}) # So we can use a trailing dot on each with_content line

          should contain_concat__fragment('puppet.conf+15-main-master').
            with_content(/^\s+reports\s+= foreman$/).
            with({}) # So we can use a trailing dot on each with_content line

          if Puppet.version >= '3.6'
            should contain_concat__fragment('puppet.conf+15-main-master').
              with_content(/^\s+environmentpath\s+= #{codedir}\/environments$/).
              with_content(/^\s+basemodulepath\s+= #{codedir}\/environments\/common:#{codedir}\/modules:#{sharedir}\/modules$/).
              with({}) # So we can use a trailing dot on each with_content line
          end

          should contain_concat__fragment('puppet.conf+20-agent').
            with_content(/^\s+classfile\s+= \$statedir\/classes.txt/).
            with({}) # So we can use a trailing dot on each with_content line

          should contain_concat__fragment('puppet.conf+30-master').
            with_content(/^\s+external_nodes\s+= #{etcdir}\/node.rb$/).
            with_content(/^\s+node_terminus\s+= exec$/).
            with_content(/^\s+ca\s+= true$/).
            with_content(/^\s+ssldir\s+= #{ssldir}$/).
            with_content(/^\s+parser\s+=\s+current$/).
            with_content(/^\s+autosign\s+= #{etcdir}\/autosign.conf \{ mode = 0664 \}$/).
            with({}) # So we can use a trailing dot on each with_content line

          should contain_concat(conf_file)

          should_not contain_file('/etc/puppet/puppet.conf').with_content(/storeconfigs/)

          should contain_file("#{etcdir}/autosign.conf")
        end

        context 'on Puppet < 4.0.0', :if => (Puppet.version < '4.0.0') do
          it 'should set configtimeout' do
            should contain_concat__fragment('puppet.conf+20-agent').
              with_content(/^\s+configtimeout\s+= 120$/)
          end
        end

        context 'on Puppet >= 4.0.0', :if => (Puppet.version >= '4.0.0') do
          it 'should not set configtimeout' do
            should contain_concat__fragment('puppet.conf+20-agent').
              without_content(/^\s+configtimeout\s+= 120$/)
          end
        end

        it 'should not configure PuppetDB' do
          should_not contain_class('puppetdb')
          should_not contain_class('puppetdb::master::config')
        end
      end

      describe "when autosign => true" do
        let :pre_condition do
          "class {'puppet':
              server   => true,
              autosign => true,
           }"
        end

        it 'should contain puppet.conf [main] with autosign = true' do
          should contain_concat__fragment('puppet.conf+30-master').
            with_content(/^\s+autosign\s+= true$/).
            with({}) # So we can use a trailing dot on each with_content line
        end
      end

      describe 'when autosign => /somedir/custom_autosign, autosign_mode => 664' do
        let :pre_condition do
          "class {'puppet':
              server        => true,
              autosign      => '/somedir/custom_autosign',
              autosign_mode => '664',
           }"
        end

        it 'should contain puppet.conf [main] with autosign = /somedir/custom_autosign { mode = 664 }' do
          should contain_concat__fragment('puppet.conf+30-master').
            with_content(/^\s+autosign\s+= \/somedir\/custom_autosign { mode = 664 }$/).
            with({}) # So we can use a trailing dot on each with_content line
        end
      end

      describe "when autosign_entries is not set" do
        let :pre_condition do
          "class {'puppet':
              server  => true,
           }"
        end

        it 'should contain autosign.conf with out content set' do
           should contain_file("#{confdir}/autosign.conf")
           should_not contain_file("#{confdir}/autosign.conf").with_content(/# Managed by Puppet/)
           should_not contain_file("#{confdir}/autosign.conf").with_content(/foo.bar/)
        end
      end

      describe "when autosign_entries set to ['foo.bar']" do
        let :pre_condition do
          "class {'puppet':
              server           => true,
              autosign_entries => ['foo.bar'],
           }"
        end

        it 'should contain autosign.conf with content set' do
           should contain_file("#{confdir}/autosign.conf")
           should contain_file("#{confdir}/autosign.conf").with_content(/# Managed by Puppet/)
           should contain_file("#{confdir}/autosign.conf").with_content(/foo.bar/)
        end
      end

      describe "when hiera_config => '$confdir/hiera.yaml'" do
        let :pre_condition do
          "class {'puppet':
              server        => true,
              hiera_config => '/etc/puppet/hiera/production/hiera.yaml',
           }"
        end

        it 'should contain puppet.conf [main] with non-default hiera_config' do
          should contain_concat__fragment('puppet.conf+15-main-master').
            with_content(/^\s+hiera_config\s+= \/etc\/puppet\/hiera\/production\/hiera.yaml$/).
            with({}) # So we can use a trailing dot on each with_content line
        end
      end

      describe 'without foreman' do
        let :pre_condition do
          "class {'puppet':
              server                => true,
              server_reports        => 'store',
              server_external_nodes => '',
           }"
        end

        it 'should contain an empty external_nodes' do
          should contain_concat__fragment('puppet.conf+30-master').with_content(/^\s+external_nodes\s+=\s+$/)
        end
      end

      describe 'without external_nodes' do
        let :pre_condition do
          "class {'puppet':
              server                => true,
              server_external_nodes => '',
           }"
        end

        it 'should not contain external_nodes' do
          should contain_concat__fragment('puppet.conf+30-master').
            with_content(/^\s+external_nodes\s+= $/).
            with_content(/^\s+node_terminus\s+= plain$/).
            with({})
        end
      end


      describe 'with server_default_manifest => true and undef content' do
        let :pre_condition do
          'class { "::puppet":
              server_default_manifest => true,
              server => true
          }'
        end

        it 'should contain default_manifest setting in puppet.conf' do
          should contain_concat__fragment('puppet.conf+15-main-master').with_content(/\s+default_manifest = \/etc\/puppet\/manifests\/default_manifest\.pp$/)
        end

        it 'should_not contain default manifest /etc/puppet/manifests/default_manifest.pp' do
          should_not contain_file('/etc/puppet/manifests/default_manifest.pp')
        end
      end

      describe 'with server_default_manifest => true and server_default_manifest_content => "include foo"' do
        let :pre_condition do
          'class { "::puppet":
              server_default_manifest => true,
              server_default_manifest_content => "include foo",
              server => true
          }'
        end

        it 'should contain default_manifest setting in puppet.conf' do
          should contain_concat__fragment('puppet.conf+15-main-master').with_content(/\s+default_manifest = \/etc\/puppet\/manifests\/default_manifest\.pp$/)
        end

        it 'should contain default manifest /etc/puppet/manifests/default_manifest.pp' do
          should contain_file('/etc/puppet/manifests/default_manifest.pp').with_content(/include foo/)
        end
      end

      describe 'with git repo' do
        let :pre_condition do
          "class {'puppet':
              server          => true,
              server_git_repo => true,
           }"
        end

        it 'should set up the environments directory' do
          should contain_file(environments_dir).with({
            :ensure => 'directory',
            :owner  => 'puppet',
          })
        end

        it 'should create the git repo' do
          should contain_file(vardir).with({
            :ensure => 'directory',
            :owner  => 'puppet',
          })

          should contain_git__repo('puppet_repo').with({
            :bare    => true,
            :target  => "#{vardir}/puppet.git",
            :user    => 'puppet',
            :require => %r{File\[#{environments_dir}\]},
          })

          should contain_file("#{vardir}/puppet.git/hooks/post-receive").with({
            :owner   => 'puppet',
            :mode    => '0755',
            :require => %r{Git::Repo\[puppet_repo\]},
            :content => %r{BRANCH_MAP = \{[^a-zA-Z=>]\}},
          })
        end

        it { should_not contain_puppet__server__env('development') }
        it { should_not contain_puppet__server__env('production') }

        context 'with directory environments' do
          let :pre_condition do
            "class {'puppet':
               server                        => true,
               server_git_repo               => true,
               server_directory_environments => true,
             }"
          end

          it 'should configure puppet.conf' do
            should_not contain_concat__fragment('puppet.conf+30-master').with_content(%r{^\s+config_version\s+=$})

            should contain_concat__fragment('puppet.conf+15-main-master').
              with_content(%r{^\s+environmentpath\s+= #{environments_dir}$})
          end
        end

        context 'with config environments' do
          let :pre_condition do
            "class {'puppet':
               server                        => true,
               server_git_repo               => true,
               server_directory_environments => false,
             }"
          end

          it 'should configure puppet.conf' do
            should contain_concat__fragment('puppet.conf+30-master').
              with_content(%r{^\s+manifest\s+= #{environments_dir}/\$environment/manifests/site.pp\n\s+modulepath\s+= #{environments_dir}/\$environment/modules$}).
              with_content(%r{^\s+config_version\s+= git --git-dir #{environments_dir}/\$environment/.git describe --all --long$})
          end
        end
      end

      describe 'with dynamic environments' do
        context 'with directory environments' do
          let :pre_condition do
            "class {'puppet':
               server                        => true,
               server_dynamic_environments   => true,
               server_directory_environments => true,
               server_environments_owner     => 'apache',
             }"
          end

          it 'should set up the environments directory' do
            should contain_file(environments_dir).with({
              :ensure => 'directory',
              :owner  => 'apache',
            })
          end

          it 'should configure puppet.conf' do
            should contain_concat__fragment('puppet.conf+15-main-master').
              with_content(%r{^\s+environmentpath\s+= #{environments_dir}\n\s+basemodulepath\s+= #{environments_dir}/common:#{codedir}/modules:#{sharedir}/modules$})
          end

          it { should_not contain_puppet__server__env('development') }
          it { should_not contain_puppet__server__env('production') }
        end

        context 'with no common modules directory' do
          let :pre_condition do
            "class {'puppet':
               server                        => true,
               server_dynamic_environments   => true,
               server_directory_environments => true,
               server_environments_owner     => 'apache',
               server_common_modules_path    => '',
             }"
          end

          it 'should configure puppet.conf' do
            should contain_concat__fragment('puppet.conf+15-main-master').
              without_content(%r{^\s+basemodulepath})
          end
        end

        context 'with config environments' do
          let :pre_condition do
            "class {'puppet':
               server                        => true,
               server_dynamic_environments   => true,
               server_directory_environments => false,
               server_environments_owner     => 'apache',
             }"
          end

          it 'should set up the environments directory' do
            should contain_file(environments_dir).with({
              :ensure => 'directory',
              :owner  => 'apache',
            })
          end

          it 'should configure puppet.conf' do
            should contain_concat__fragment('puppet.conf+30-master').
              with_content(%r{^\s+manifest\s+= #{environments_dir}/\$environment/manifests/site.pp\n\s+modulepath\s+= #{environments_dir}/\$environment/modules$})
          end

          it { should_not contain_puppet__server__env('development') }
          it { should_not contain_puppet__server__env('production') }
        end
      end

      describe 'with SSL path overrides' do
        let :pre_condition do
          "class {'puppet':
              server                  => true,
              server_foreman_ssl_ca   => '/etc/example/ca.pem',
              server_foreman_ssl_cert => '/etc/example/cert.pem',
              server_foreman_ssl_key  => '/etc/example/key.pem',
           }"
        end

        it 'should pass SSL parameters to the ENC' do
          should contain_class('foreman::puppetmaster').with({
            :ssl_ca   => '/etc/example/ca.pem',
            :ssl_cert => '/etc/example/cert.pem',
            :ssl_key  => '/etc/example/key.pem',
          })
        end
      end

      describe 'with a PuppetDB host set' do
        let :pre_condition do
          "class {'puppet':
              server                      => true,
              server_puppetdb_host        => 'mypuppetdb.example.com',
              server_storeconfigs_backend => 'puppetdb',
           }"
        end

        it 'should configure PuppetDB' do
          should compile.with_all_deps
          should contain_class('puppetdb::master::config').with({
            :puppetdb_server             => 'mypuppetdb.example.com',
            :puppetdb_port               => 8081,
            :puppetdb_soft_write_failure => false,
            :manage_storeconfigs         => false,
            :restart_puppet              => false,
          })
        end
      end

      describe 'with a puppet git branch map' do
        let :pre_condition do
          "class {'puppet':
              server                => true,
              server_git_repo       => true,
              server_git_branch_map => { 'a' => 'b', 'c' => 'd' }
           }"
        end

        it 'should add the branch map to the post receive hook' do
          should contain_file("#{vardir}/puppet.git/hooks/post-receive").
            with_content(/BRANCH_MAP = \{\n  "a" => "b",\n  "c" => "d",\n\}/)
        end
      end

      describe 'with additional settings' do
        let :pre_condition do
          "class {'puppet':
              server                      => true,
              server_additional_settings => {stringify_facts => true},
           }"
        end

        it 'should configure puppet.conf' do
          should contain_concat__fragment('puppet.conf+30-master').
            with_content(/^\s+stringify_facts\s+= true$/).
            with({}) # So we can use a trailing dot on each with_content line
        end
      end

      describe 'directory environments default' do
        let :pre_condition do
          "class {'puppet':
             server => true,
           }"
        end

        context 'on old Puppet', :if => (Puppet.version < '3.6.0') do
          it 'should be disabled' do
            should contain_concat__fragment('puppet.conf+30-master').
              without_content(%r{^\s+environmentpath\s+=$})
          end
        end

        context 'on Puppet 3.6.0+', :if => (Puppet.version >= '3.6.0') do
          it 'should be enabled' do
            should contain_concat__fragment('puppet.conf+15-main-master').
              with_content(%r{^\s+environmentpath\s+= #{environments_dir}$})
          end
        end
      end

      describe 'with server_parser => future' do
        let :pre_condition do
          "class {'puppet':
            server => true,
            server_parser => 'future',
          }"
        end

        it 'should configure future parser' do
          should contain_concat__fragment('puppet.conf+30-master').
            with_content(/^\s+parser\s+=\s+future$/)
        end
      end

      describe 'with server_environment_timeout set' do
        let :pre_condition do
          "class {'puppet':
            server => true,
            server_environment_timeout => '10m',
          }"
        end

        it 'should configure environment_timeout accordingly' do
          should contain_concat__fragment('puppet.conf+30-master').
            with_content(/^\s+environment_timeout\s+=\s+10m$/)
        end
      end

      describe 'with no ssldir managed for master' do
        let :pre_condition do
          "class {'puppet': server => true, server_ssl_dir_manage => false}"
        end

        it 'should not contain ssl_dir configuration setting in the master section' do
          should_not contain_concat__fragment('puppet.conf+30-master').
            with_content(/^\s+ssl_dir\s+=\s+.*$/)
        end
      end

      describe 'with nondefault CA settings' do
        context 'with server_ca => false' do
          let :pre_condition do
            "class {'puppet':
              server => true,
              server_ca => false,
            }"
          end

          it 'should create the ssl directory' do
            should contain_exec('puppet_server_config-create_ssl_dir')
          end

          it 'should not generate CA certificates' do
            should_not contain_exec('puppet_server_config-generate_ca_cert')
          end
        end
      end
    end
  end
end
