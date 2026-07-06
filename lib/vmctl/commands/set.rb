# frozen_string_literal: true
# lib/vmctl/commands/set.rb
require 'optparse'
require_relative 'base'
require_relative '../netgraph'
require_relative '../allocator'
require_relative '../cloudinit'

module VMCtl
  module Commands
    # set <vm> [field flags]  -- edit scalar inventory fields.
    class Set < Base
      def call(args)
        opts = {}
        parser = OptionParser.new do |p|
          p.on('--autostart')    { opts[:autostart] = true }
          p.on('--no-autostart') { opts[:autostart] = false }
          p.on('--graphics')     { opts[:graphics] = true }
          p.on('--no-graphics')  { opts[:graphics] = false }
          p.on('--network NET')  { |v| opts[:network] = v }
          p.on('--mtu N')        { |v| opts[:mtu] = v }
          p.on('--cpus N')      { |v| opts[:cpus] = v }
          p.on('--memory SIZE') { |v| opts[:memory] = v }
          p.on('--mac MAC')      { |v| opts[:mac] = v }
          p.on('--config TMPL')  { |v| opts[:config] = v }
          p.on('--iso FILE')     { |v| opts[:iso] = v }
          p.on('--no-iso')       { opts[:iso] = false }
          p.on('--cloud-init TMPL') { |v| opts[:cloud_init] = v }
          p.on('--no-cloud-init')   { opts[:cloud_init] = false }
          p.on('--var KV')          { |v| (opts[:vars] ||= {}); k, val = v.split('=', 2); raise CommandError, "invalid --var #{v.inspect}" unless k =~ /\A\w+\z/ && val; opts[:vars][k] = val }
        end
        rest = parser.parse(args)
        name = rest.shift
        raise CommandError, 'set requires a VM name' unless name
        raise CommandError, 'set requires at least one field to change' if opts.empty?
        vm = vm_for(name)
        changed = apply!(vm, opts)
        config.save(config.path) unless executor.dry_run?
        puts "updated #{name}: #{changed.join(', ')}"
        note_next_boot(vm, 'these changes')
      end

      private

      def apply!(vm, opts)
        e = vm.entry
        changed = []
        if opts.key?(:autostart)
          e.autostart = opts[:autostart]
          changed << "autostart=#{e.autostart}"
        end
        if opts.key?(:graphics)
          e.graphics = opts[:graphics]
          changed << "graphics=#{e.graphics}"
        end
        if opts.key?(:network)
          Netgraph.new(executor).ensure_bridge!(opts[:network]) unless opts[:network] == 'none'
          e.network = opts[:network]
          changed << "network=#{e.network}"
        end
        if opts.key?(:mtu)
          e.mtu = parse_mtu(opts[:mtu])
          changed << "mtu=#{e.mtu}"
        end
        if opts.key?(:cpus)
          e.cpus = positive_int!(opts[:cpus], '--cpus')
          changed << "cpus=#{e.cpus}"
        end
        if opts.key?(:memory)
          e.memory = valid_size!(opts[:memory], '--memory')
          changed << "memory=#{e.memory}"
        end
        if opts.key?(:mac)
          e.mac = resolve_mac(opts[:mac], vm.name)
          changed << "mac=#{e.mac}"
        end
        if opts.key?(:config)
          validate_template!(opts[:config])
          e.config = opts[:config]
          changed << "config=#{e.config}"
        end
        apply_iso!(vm, opts[:iso], changed) if opts.key?(:iso)
        apply_cloud_init!(vm, opts, changed) if opts.key?(:cloud_init) || opts.key?(:vars)
        changed
      end

      def parse_mtu(v)
        n = Integer(v, exception: false)
        raise CommandError, "invalid --mtu #{v.inspect}" if n.nil? || n <= 0
        n
      end

      def resolve_mac(mac, name)
        return Allocator.new(config).generate_mac(name) if mac == 'generate'
        mac
      end

      def validate_template!(tmpl)
        path = File.join(config.defaults.config_dir, tmpl)
        raise CommandError, "template not found: #{path}" unless File.exist?(path)
      end

      def apply_iso!(vm, iso, changed)
        e = vm.entry
        if iso == false
          e.iso = nil
          changed << 'iso=(none)'
        else
          path = File.expand_path(iso)
          raise CommandError, "iso not found: #{path}" unless File.exist?(path)
          e.iso = path
          changed << "iso=#{path}"
        end
      end

      def apply_cloud_init!(vm, opts, changed)
        e = vm.entry
        if opts[:cloud_init] == false
          e.cloud_init = nil
          changed << 'cloud_init=(none)'
          return
        end
        ci = e.cloud_init ? e.cloud_init.dup : {}
        ci['user_data'] = opts[:cloud_init] if opts[:cloud_init]
        raise CommandError, 'set --var requires cloud-init on the VM' if ci['user_data'].to_s.empty?
        vars = (ci['vars'] || {}).merge(opts[:vars] || {})
        template = cloud_init_template(ci['user_data'])
        raise CommandError, "cloud-init template not found: #{template}" unless File.exist?(template)
        CloudInit.new(executor).build_seed(vm, template, vars)
        ci['vars'] = vars unless vars.empty?
        e.cloud_init = ci
        changed << "cloud_init=#{ci['user_data']}"
      end

    end
  end
end
