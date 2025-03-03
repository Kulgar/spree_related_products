# frozen_string_literal: true

module RelatedProducts
  module Spree
    module ProductDecorator
      def self.prepended(base)
        base.has_many :relations, -> { order(:position) }, class_name: 'Spree::Relation', as: :relatable
        base.has_many :relation_types, -> { distinct.reorder(nil) }, class_name: 'Spree::RelationType', through: :relations

        # When a Spree::Product is destroyed, we also want to destroy all
        # Spree::Relations "from" it as well as "to" it.
        base.after_destroy :destroy_product_relations
        base.extend ClassMethods
      end

      module ClassMethods
        # Returns all the Spree::RelationType's which apply_to this class.
        def relation_types
          ::Spree::RelationType.where(applies_to: to_s).order(:name)
        end

        # The AREL Relations that will be used to filter the resultant items.
        #
        # By default this will remove any items which are deleted,
        # or not yet available.
        #
        # You can override this method to fine tune the filter. For example,
        # to only return Spree::Product's with more than 2 items in stock, you could
        # do the following:
        #
        #   def self.relation_filter
        #     set = super
        #     set.where('spree_products.count_on_hand >= 2')
        #   end
        #
        # This could also feasibly be overridden to sort the result in a
        # particular order, or restrict the number of items returned.
        def relation_filter
          where('spree_products.deleted_at' => nil)
            .where('spree_products.available_on IS NOT NULL')
            .where('spree_products.available_on <= ?', Time.now)
            .references(self)
        end
      end

      # Decides if there is a relevant Spree::RelationType related to this class
      # which should be returned for this method.
      #
      # If so, it calls relations_for_relation_type. Otherwise it passes
      # it up the inheritance chain.
      def method_missing(method, *args)
        relation_type = find_relation_type(method)
        if relation_type.nil?
          super
        else
          relations_for_relation_type(relation_type)
        end
      end

      def has_related_products?(relation_method)
        find_relation_type(relation_method).present?
      end

      def destroy_product_relations
        # First we destroy relationships "from" this Product to others.
        relations.destroy_all
        # Next we destroy relationships "to" this Product.
        ::Spree::Relation.where(related_to_type: self.class.to_s).where(related_to_id: id).destroy_all
      end

      private

      def find_relation_type(relation_name)
        self.class.relation_types.detect do |rt|
          format_name(rt.name) == format_name(relation_name)
        end
      rescue ActiveRecord::StatementInvalid
        # This exception is throw if the relation_types table does not exist.
        # And this method is getting invoked during the execution of a migration
        # from another extension when both are used in a project.
        nil
      end

      # Returns all the Products that are related to this record for the given RelationType.
      #
      # Uses the Relations to find all the related items, and then filters
      # them using +Product.relation_filter+ to remove unwanted items.
      def relations_for_relation_type(relation_type)
        # Find all the relations that belong to us for this RelationType, ordered by position
        related_ids = relations.where(relation_type_id: relation_type.id)
                              .order(:position)
                              .select(:related_to_id)

        # Construct a query for all these records
        result = self.class.where(id: related_ids)

        # Merge in the relation_filter if it's available
        result = result.merge(self.class.relation_filter) if relation_filter

        # make sure results are in same order as related_ids array (position order)
        result.where(id: related_ids).order(:position) if result.present?

        result
      end

      # Simple accessor for the class-level relation_filter.
      # Could feasibly be overloaded to filter results relative to this
      # record (eg. only higher priced items)
      def relation_filter
        self.class.relation_filter
      end

      def format_name(name)
        name.to_s.downcase.tr(' ', '_').pluralize
      end
    end
  end
end

::Spree::Product.prepend(RelatedProducts::Spree::ProductDecorator) if ::Spree::Product.included_modules.exclude?(RelatedProducts::Spree::ProductDecorator)
