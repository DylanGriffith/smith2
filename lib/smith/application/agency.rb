# -*- encoding: utf-8 -*-
require 'dm-core'

module Smith
  class Agency

    include Logger

    attr_reader :agents, :agent_processes

    def initialize(opts={})
      DataMapper.setup(:default, "yaml:///var/tmp/smith")

      @agent_processes = AgentCache.new(:paths => opts.delete(:paths))
    end

    def setup_queues
      Messaging::Receiver.new('agency.control').ready do |receiver|
        receiver.subscribe_and_reply do |header,payload,responder|

          # Add a logger proc to the responder chain.
          responder.callback do |ret|
            logger.debug(ret) if ret && !ret.empty?
          end

          begin
            Command.run(payload.command, payload.args, :agency => self,  :agents => @agent_processes, :responder => responder)
          rescue Command::UnkownCommandError => e
            responder.callback {|ret| logger.warn(ret) if ret && !ret.empty?}
            responder.value("Unknown command: #{payload.command}")
          end
        end
      end

      Messaging::Receiver.new('agent.lifecycle').ready do |receiver|
        receiver.subscribe do |header, payload|
          case payload.state
          when 'dead'
            dead(payload)
          when 'acknowledge_start'
            acknowledge_start(payload)
          when 'acknowledge_stop'
            acknowledge_stop(payload)
          else
            logger.warn("Unkown command received on agent.lifecycle queue: #{payload.state.inspect}")
          end
        end
      end

      Messaging::Receiver.new('agent.keepalive').ready do |receiver|
        receiver.subscribe do |header, agent_data|
          keep_alive(agent_data)
        end
      end
    end

    def start_monitoring
      @agent_monitor = AgentMonitoring.new(@agent_processes)
      @agent_monitor.start_monitoring
    end

    # Stop the agency. This will wait for one second to ensure
    # that any messages are flushed.
    def stop
      Smith.stop(true)
    end

    private

    def acknowledge_start(agent_data)
      @agent_processes[agent_data.name].tap do |agent_process|
        if agent_data.pid == agent_process.pid
          agent_process.monitor = agent_data.monitor
          agent_process.singleton = agent_data.singleton
          agent_process.acknowledge_start
        else
          logger.error("Agent reports different pid during acknowledge_start: #{agent_data.name}")
        end
      end
    end

    def acknowledge_stop(agent_data)
      @agent_processes[agent_data.name].tap do |agent_process|
        if agent_data.pid == agent_process.pid
          agent_process.pid = nil
          agent_process.monitor = nil
          agent_process.singleton = nil
          agent_process.started_at = nil
          agent_process.last_keep_alive = nil
          agent_process.acknowledge_stop
        else
          if agent_process.pid
            logger.error("Agent reports different pid during acknowledge_stop: #{agent_data.name}")
          end
        end
      end
    end

    def dead(agent_data)
      @agent_processes[agent_data.name].no_process_running
      logger.fatal("Agent is dead: #{agent_data.name}")
    end

    def keep_alive(agent_data)
      @agent_processes[agent_data.name].tap do |agent_process|
        if agent_data.pid == agent_process.pid
          agent_process.last_keep_alive = agent_data.time
          logger.verbose("Agent keep alive: #{agent_data.name}: #{agent_data.time}")

          # We need to call save explicitly here as the keep alive is not part of
          # the state_machine which is the thing that writes the state to disc.
          agent_process.save
        else
          if agent_process.pid
            logger.error("Agent reports different pid during acknowledge_stop: #{agent_data.name}")
          end
        end
      end
    end

    # FIXME this doesn't work.
    def delete_agent_process(agent_pid)
      @agent_processes.invalidate(agent_pid)
      AgentProcess.first('pid' => agent_pid).destroy!
    end
  end
end
