require 'chewy/type/adapter/base'

module Chewy
  class Type
    module Adapter
      # This adapter provides an ability to import documents from any
      # source. You can actually use any class or even a symbol as
      # a target.
      #
      # In case if a class is used - some of the additional features
      # are available: it is possible to provide the default import
      # data (used on reset) and source objects loading logic.
      #
      # @see #import
      # @see #load
      class Object < Base
        # The signature of the type definition.
        #
        # @example
        #   define_type :geoname
        #   define_type Geoname
        #   define_type -> { Geoname.all_the_places }, name: 'geoname'
        #
        # @param target [Class, Symbol, String, Proc] a source of data and everything
        # @option options [String, Symbol] :name redefines the inferred type name if necessary
        # @option options [String, Symbol] :import_all_method redefines import method name
        # @option options [String, Symbol] :load_all_method redefines batch load method name
        # @option options [String, Symbol] :load_one_method redefines per-object load method name
        def initialize(target, **options)
          @target = target
          @options = options
        end

        # Name is used for the type class creation. Inferred from the target
        # by default if possible.
        #
        # @example
        #   # defines MyIndex::Geoname
        #   define_type :geoname
        #   # still defines MyIndex::Geoname
        #   define_type -> { Geoname.all_the_places }, name: 'geoname'
        #
        # @return [String]
        def name
          @name ||= (options[:name] || @target).to_s.camelize.demodulize
        end

        # While for ORM adapters it returns an array of ids for the passed
        # collection, for the object adapter it returns the collection itself.
        #
        # @param collection [Array<Object>, Object] a collection or an object
        # @return [Array<Object>]
        def identify(collection)
          Array.wrap(collection)
        end

        # For the object adapter this method tries to fetch :id and requested
        # fields from the target `import_all_method` when defined. Otherwise
        # it tries to call the target `pluck_method`, which is configurable and
        # `pluck` by default. The `pluck_method` have to act exactly the same
        # way as the AR one. It returns an empty array when none of the methods
        # are found.
        #
        # @example
        #   class Geoname
        #     self < class
        #       def self.pluck(*fields)
        #         if fields.one?
        #           whatever_source.map { |object| object.send(fields.first) }
        #         else
        #           whatever_source.map do |object|
        #             fields.map { |field| object.send(field) }
        #           end
        #         end
        #       end
        #     end
        #   end
        #
        # @see Chewy::Type::Adapter::Base#default_scope_pluck
        # @return [Array<Object>, Array<Array<Object>>]
        def default_scope_pluck(*fields)
          if @target.respond_to?(import_all_method)
            everything = @target.send(import_all_method)
            if fields.blank?
              everything.map { |object| object_field(object, :id) || object }
            else
              everything.map do |object|
                fields.map { |field| object_field(object, field) }
                  .unshift(object_field(object, :id) || object)
              end
            end
          elsif @target.respond_to?(pluck_method)
            fields.unshift(:id)
            @target.send(pluck_method, *fields)
          else
            []
          end
        end

        # This method is used internally by `Chewy::Type.import`.
        #
        # The idea is that any object can be imported to ES if
        # it responds to `#to_json` method.
        #
        # If method `destroyed?` is defined for object (or, in case of hash object,
        # it has `:_destroyed` or `'_destroyed'` key) and returns `true` or object
        # satisfy `delete_if` type option then object will be deleted from index.
        # But in order to be destroyable, objects need to respond to `id` method
        # or have an `id` key so ElasticSearch could know which one to delete.
        #
        # If nothing is passed the method tries to call `import_all_method`,
        # which is `call` by default, on target to get the default objects batch.
        #
        # @example
        #   class Geoname
        #     self < class
        #       def self.call
        #         FancyGeoAPI.all_points_collection
        #       end
        #       alias_method :import_all, :call
        #     end
        #   end
        #
        #   # All the folloving variants will work:
        #   define_type Geoname
        #   define_type Geoname, import_all_method: 'import_all'
        #   define_type -> { FancyGeoAPI.all_points_collection }, name: 'geoname'
        #
        # @param args [Array<#to_json>]
        # @option options [Integer] :batch_size import processing batch size
        # @return [true, false]
        def import(*args, &block)
          options = args.extract_options!
          options[:batch_size] ||= BATCH_SIZE

          objects = if args.empty? && @target.respond_to?(import_all_method)
            @target.send(import_all_method)
          else
            args.flatten.compact
          end

          import_objects(objects, options, &block)
        end

        # This method is used internally by the request DSL when the
        # collection of ORM/ODM objects is requested.
        #
        # Options usage is implemented by `load_all_method` and `load_one_method`.
        #
        # If none of the `load_all_method` or `load_one_method` is implemented
        # for the target - the method will return nil. This means that the
        # loader will return an array `Chewy::Type` objects that actually was passed.
        #
        # To use loading for objects it is obviously required to provide
        # some meaningful ids for ES documents.
        #
        # @example
        #   class Geoname
        #     def self.load_all(wrappers, options)
        #       if options[:additional_data]
        #         wrappers.map do |wrapper|
        #           FancyGeoAPI.point_by_name(wrapper.name)
        #         end
        #       else
        #         wrappers
        #       end
        #     end
        #   end
        #
        #   MyIndex::Geoname.load(additional_data: true).objects
        #
        # @param ids [Array<Hash>] an array of ids from ES hits
        # @param options [Hash] any options passed here with the request DSL `load` method.
        # @return [Array<Object>, nil]
        def load(ids, **options)
          if target.respond_to?(load_all_method)
            if target.method(load_all_method).arity == 1
              target.send(load_all_method, ids)
            else
              target.send(load_all_method, ids, options)
            end
          elsif target.respond_to?(load_one_method)
            if target.method(load_one_method).arity == 1
              ids.map { |hit| target.send(load_one_method, hit) }
            else
              ids.map { |hit| target.send(load_one_method, hit, options) }
            end
          end
        end

      private

        def import_objects(objects, options)
          objects.each_slice(options[:batch_size]).map do |group|
            yield grouped_objects(group)
          end.all?
        end

        def delete_from_index?(object)
          delete = super
          delete ||= object.destroyed? if object.respond_to?(:destroyed?)
          delete ||= object[:_destroyed] || object['_destroyed'] if object.is_a?(Hash)
          !!delete
        end

        def object_field(object, name)
          if object.respond_to?(name)
            object.send(name)
          elsif object.is_a?(Hash)
            object[name.to_sym] || object[name.to_s]
          end
        end

        def import_all_method
          @import_all_method ||= options[:import_all_method] || :call
        end

        def pluck_method
          @pluck_method ||= options[:pluck_method] || :pluck
        end

        def load_all_method
          @load_all_method ||= options[:load_all_method] || :load_all
        end

        def load_one_method
          @load_one_method ||= options[:load_one_method] || :load_one
        end
      end
    end
  end
end
