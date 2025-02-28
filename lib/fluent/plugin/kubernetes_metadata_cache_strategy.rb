# frozen_string_literal: true

#
# Fluentd Kubernetes Metadata Filter Plugin - Enrich Fluentd events with
# Kubernetes metadata
#
# Copyright 2017 Red Hat, Inc.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#   http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

module KubernetesMetadata
  module CacheStrategy
    def get_pod_metadata(key, namespace_name, pod_name, time, batch_miss_cache) # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity
      metadata = {}
      ids = @id_cache[key]
      if ids.nil?
        @stats.bump(:id_cache_miss)
        if batch_miss_cache.key?("#{namespace_name}_#{pod_name}")
          return batch_miss_cache["#{namespace_name}_#{pod_name}"]
        end

        pod_metadata = fetch_pod_metadata(namespace_name, pod_name)
        if @skip_namespace_metadata
          ids = { pod_id: pod_metadata['pod_id'] }
          @id_cache[key] = ids
          return pod_metadata
        end

        namespace_metadata = fetch_namespace_metadata(namespace_name)
        ids = { pod_id: pod_metadata['pod_id'], namespace_id: namespace_metadata['namespace_id'] }
        if !ids[:pod_id].nil? && !ids[:namespace_id].nil?
          # pod found and namespace found
          metadata = pod_metadata
          metadata.merge!(namespace_metadata)
        else
          if ids[:pod_id].nil? && !ids[:namespace_id].nil? # rubocop:disable Style/IfInsideElse
            # pod not found, but namespace found
            @stats.bump(:id_cache_pod_not_found_namespace)
            ns_time = Time.parse(namespace_metadata['creation_timestamp'])
            if ns_time <= Time.at(time.to_f) # rubocop:disable Metrics/BlockNesting
              # namespace is older then record for pod
              ids[:pod_id] = key
              metadata = @cache.fetch(ids[:pod_id]) do
                { 'pod_id' => ids[:pod_id] }
              end
            end
            metadata.merge!(namespace_metadata)
          else
            if !ids[:pod_id].nil? && ids[:namespace_id].nil? # rubocop:disable Metrics/BlockNesting
              # pod found, but namespace NOT found
              # this should NEVER be possible since pod meta can
              # only be retrieved with a namespace
              @stats.bump(:id_cache_namespace_not_found_pod)
            else
              # nothing found
              @stats.bump(:id_cache_orphaned_record)
            end
            if @allow_orphans # rubocop:disable Metrics/BlockNesting
              log.trace("orphaning message for: #{namespace_name}/#{pod_name} ")
              metadata = {
                'orphaned_namespace' => namespace_name,
                'namespace_name' => @orphaned_namespace_name,
                'namespace_id' => @orphaned_namespace_id
              }
            else
              metadata = {}
            end
            batch_miss_cache["#{namespace_name}_#{pod_name}"] = metadata
          end
        end
        @id_cache[key] = ids unless batch_miss_cache.key?("#{namespace_name}_#{pod_name}")
      else
        # SLOW PATH
        metadata = @cache.fetch(ids[:pod_id]) do
          @stats.bump(:pod_cache_miss)
          m = fetch_pod_metadata(namespace_name, pod_name)
          m.nil? || m.empty? ? { 'pod_id' => ids[:pod_id] } : m
        end
        namespace_metadata = @namespace_cache.fetch(ids[:namespace_id]) do
          m = unless @skip_namespace_metadata
                @stats.bump(:namespace_cache_miss)
                fetch_namespace_metadata(namespace_name)
              end
          m.nil? || m.empty? ? { 'namespace_id' => ids[:namespace_id] } : m
        end
        metadata.merge!(namespace_metadata)
      end

      # remove namespace info that is only used for comparison
      metadata.delete('creation_timestamp')
      metadata.delete_if { |_k, v| v.nil? }
    end
  end
end
