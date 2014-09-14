module CalculableAttrs::ActiveRecord::Relation
  JOINED_RELATION_NAME = 'calculated_attrs'

  def includes_calculable_attrs(*attrs)
    spawn.includes_calculable_attrs!(*attrs)
  end
  alias_method :calculate_attrs, :includes_calculable_attrs

  def includes_calculable_attrs!(*attrs)
    set_calculable_attrs_included(refine_calculable_attrs(attrs))
    self
  end
  alias_method :calculate_attrs!, :includes_calculable_attrs!

  def joins_calculable_attrs(*attrs)
    spawn.joins_calculable_attrs!(*attrs)
  end

  def joins_calculable_attrs!(*attrs)
    set_calculable_attrs_joined(refine_calculable_attrs(attrs))
    self
  end


  def self.included(base)
    base.class_eval do
      alias_method :calculable_orig_exec_queries, :exec_queries
      alias_method :calculable_orig_calculate, :calculate
      def exec_queries
        if calculable_attrs_joined.empty?
          calculable_orig_exec_queries
        else
          wrap_with_left_joins_and_exec_queries
        end
        apped_calculable_attrs
        @records
      end

      def calculate(operation, column_name, options = {})
        if calculable_attrs_joined.empty?
          calculable_orig_calculate(operation,column_name,options)
        else
          relation = wrap_with_calculable_joins(spawn)
          relation.calculable_orig_calculate(operation,column_name,options)
        end
      end
    end
  end

  private



  def wrap_with_left_joins_and_exec_queries
    relation = wrap_with_calculable_joins(spawn)
    @records = relation.send(:calculable_orig_exec_queries)
    @loaded = true
  end

  def refine_calculable_attrs(attrs)
    attrs.reject!(&:blank?)
    attrs.flatten!
    attrs = [true] if attrs.empty?
    attrs
  end

  def calculable_attrs_joined
    @values[:calculable_attrs_joined] || []
  end

  def set_calculable_attrs_joined(values)
    raise ImmutableRelation if @loaded
    @values[:calculable_attrs_joined] = [] unless @values[:calculable_attrs_joined]
    @values[:calculable_attrs_joined] |= values
  end

  def calculable_attrs_included
    @values[:calculable_attrs_included] || []
  end

  def set_calculable_attrs_included(values)
    raise ImmutableRelation if @loaded
    @values[:calculable_attrs_included] = [] unless @values[:calculable_attrs_included]
    @values[:calculable_attrs_included] |= values
  end

  def wrap_with_calculable_joins(relation)
    scope = CalculableAttrs::ModelCalculableAttrsScope.new(klass)
    scope.add_attrs(calculable_attrs_joined)

    original_sql = relation.to_sql

    sql_parser = CalculableAttrs::Utils::SqlParser.new(original_sql)
    #select_sql_snippets = [sql_parser.first_select_snippet]
    where_sql_snippet = sql_parser.last_where_snippet
    relation.reset


    scope.calculators_to_use.each_with_index do |calcualtor, index|
      joined_relation_name = '__' + JOINED_RELATION_NAME + '_' + index.to_s + '__'

      attrs_to_calculate = scope.attrs && calcualtor.attrs
      left_join_sql = "LEFT JOIN ( #{ calcualtor.query_with_grouping(attrs_to_calculate, nil).to_sql })" +
        " AS #{ joined_relation_name }" +
        " ON #{ joined_relation_name }.#{ calcualtor.calculable_foreign_key } = #{ klass.table_name }.id"

      # calculable_values_sql = attrs_to_calculate.map do |attr|
      #   attr_name = "#{ klass.name.underscore }_#{ attr }"
      #   left_join_sql.sub!(" AS #{ attr }", " AS #{ attr_name }")
      #   klass.send(:sanitize_sql, ["COALESCE(#{ joined_relation_name }.#{ attr_name }, ?) AS #{ attr_name }", calcualtor.default(attr)])
      # end.join(',')
      # select_sql_snippets << calculable_values_sql

      if where_sql_snippet
        attrs_to_calculate.each do |attr|
          original_names = [
            "#{ klass.table_name.underscore }.#{ attr }",
            "\"#{ klass.table_name.underscore }\".#{ attr }",
            "#{ klass.table_name.underscore }.\"#{ attr }\"",
            "\"#{ klass.table_name.underscore }\".\"#{ attr }\"",
          ]
          replacement_name = "#{ joined_relation_name }.#{ attr }"
          replacement = klass.send(:sanitize_sql, ["COALESCE(#{ replacement_name }, ?)", calcualtor.default(attr)])
          original_names.each { |original_name| where_sql_snippet.gsub!(original_name, replacement) }
        end
      end

      relation.joins!(left_join_sql)

    end
    #sql_select = select_sql_snippets.join(',')
    #relation.rewhere(where_sql_snippet) if where_sql_snippet
    if where_sql_snippet
      relation.where_values = nil
      relation.where!(where_sql_snippet)
    end
    #relation._select!(sql_select)
    relation
  end



  def apped_calculable_attrs
    append_included_calculable_attrs
    #append_joinded_calculable_attrs
  end

  def append_included_calculable_attrs
    unless calculable_attrs_included.empty? && calculable_attrs_joined.empty?
      #attrs = calculable_attrs_included - calculable_attrs_joined
      attrs = calculable_attrs_included | calculable_attrs_joined
      models_calculable_scopes = collect_calculable_scopes(attrs)
      collect_models_ids(models_calculable_scopes, @records, attrs)
      models_calculable_scopes.values.each { |scope| scope.calculate }
      put_calculated_values(models_calculable_scopes, @records, attrs)
    end

    @records
  end

  def append_joinded_calculable_attrs
    unless calculable_attrs_joined.empty?
      put_joined_calculated_values(@records)
    end
    @records
  end

  def collect_calculable_scopes(attrs)
    models_calculable_scopes= {}
    collect_models_calculable_attrs(models_calculable_scopes, klass, attrs)
    models_calculable_scopes.select { |model, scope| scope.has_attrs }
  end

  def collect_models_calculable_attrs(models_calculable_scopes, klass, attrs_to_calculate)
    attrs_to_calculate = [attrs_to_calculate] unless attrs_to_calculate.is_a?(Array)
    scope = (models_calculable_scopes[klass] ||= CalculableAttrs::ModelCalculableAttrsScope.new(klass))
    attrs_to_calculate.each do |attrs_to_calculate_item|
      case attrs_to_calculate_item
        when Symbol
          if klass.reflect_on_association(attrs_to_calculate_item)
            collect_association_calculable_attrs(models_calculable_scopes, klass, attrs_to_calculate_item, true)
          else
            scope.add_attr(attrs_to_calculate_item)
          end
        when true
          scope.add_all_attrs
        when Hash
          attrs_to_calculate_item.each do |association_name, association_attrs_to_calculate|
            collect_association_calculable_attrs(models_calculable_scopes, klass, association_name, association_attrs_to_calculate)
        end
      end
    end
  end

  def collect_association_calculable_attrs(models_calculable_scopes, klass, association_name, association_attrs_to_calculate)
    association = klass.reflect_on_association(association_name)
    if association
      collect_models_calculable_attrs(models_calculable_scopes, association.klass, association_attrs_to_calculate)
    else
      p "CALCULABLE_ATTRS: WAINING: Model #{ klass.name } doesn't have association attribute #{ association_name }."
    end
  end

  def collect_models_ids(models_calculable_scopes, records, attrs_to_calculate)
    iterate_scoped_records_recursively(models_calculable_scopes, records, attrs_to_calculate) do |scope, record|
      scope.add_id(record.id)
    end
  end


  def put_calculated_values(models_calculable_scopes, records, attrs_to_calculate)
    iterate_scoped_records_recursively(models_calculable_scopes, records, attrs_to_calculate) do |scope, record|
      record.calculable_attrs_values = scope.calculated_attrs_values(record.id)
    end
  end

  def put_joined_calculated_values(records)
    joined_attrs = calculable_attrs_joined
    joined_attrs = klass.calculable_attrs if joined_attrs == [true]
    unless joined_attrs.empty?
      names_hash = joined_attrs.map {|attr| [attr, "#{ klass.name.underscore }_#{ attr }"]}.to_h
      records.each do |record|
        names_hash.each do |attr_name, attr_full_name|
          value = record.send(attr_full_name)
          record.set_calculable_attr_value(attr_name, value)
        end
      end
    end
  end

  def iterate_scoped_records_recursively(models_calculable_scopes, records, attrs_to_calculate, &block)
    iterate_records_recursively(records, attrs_to_calculate) do |record|
      scope = models_calculable_scopes[record.class]
      block.call(scope, record) if scope
    end
  end

  def iterate_records_recursively(records, attrs_to_calculate, &block)
    records = [records] unless records.is_a?(Array)

    records.each do |record|
      block.call(record)

      attrs_to_calculate.select {|item| item.is_a?(Hash)}.each do |hash|
        hash.each do |association_name, association_attributes|
          if record.respond_to?(association_name)
            associated_records = record.send(association_name)
            associated_records = associated_records.respond_to?(:to_a) ? associated_records.to_a : associated_records
            iterate_records_recursively(associated_records, attrs_to_calculate, &block)
          end
        end
      end
    end
  end
end
