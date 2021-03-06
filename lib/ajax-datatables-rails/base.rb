module AjaxDatatablesRails
  class Base
    extend Forwardable
    include ActiveRecord::Sanitization::ClassMethods
    class MethodNotImplementedError < StandardError; end

    attr_reader :view, :options, :sortable_columns, :searchable_columns
    def_delegator :@view, :params, :params

    def initialize(view, options = {})
      @view = view
      @options = options
      load_paginator
    end

    def config
      @config ||= AjaxDatatablesRails.config
    end

    def sortable_columns
      @sortable_columns ||= []
    end


    def view_columns
      @view_columns ||= []
    end

    def searchable_columns
      @searchable_columns ||= []
    end

    def data
      fail(
        MethodNotImplementedError,
        'Please implement this method in your class.'
      )
    end

    def get_raw_records
      fail(
        MethodNotImplementedError,
        'Please implement this method in your class.'
      )
    end

    def as_json(options = {})
      {
        :draw => params[:draw].to_i,
        :recordsTotal =>  get_raw_records.count(:all),
        :recordsFiltered => filter_records(get_raw_records).count(:all),
        :data => data
      }
    end

    def self.deprecated(message, caller = Kernel.caller[1])
      warning = caller + ": " + message

      if(respond_to?(:logger) && logger.present?)
        logger.warn(warning)
      else
        warn(warning)
      end
    end

    private

    def records
      @records ||= fetch_records
    end

    def fetch_records
      records = get_raw_records
      records = sort_records(records) if params['order'].present?
      records = filter_records(records) if params['search'].present?
      records = paginate_records(records) unless params['length'].present? && params['length'] == '-1'
      records
    end

    def sort_records(records)
      sort_by = []
      if params[:order].is_a?(String)
        JSON.parse(params[:order]).each do |item|
          sort_by << "#{sort_column(item)} #{sort_direction(item)}"
        end
      else
        params[:order].each_value do |item|
          sort_by << "#{sort_column(item)} #{sort_direction(item)}"
        end
      end
      records.order(sort_by.join(", "))
    end


    def paginate_records(records)
      fail(
        MethodNotImplementedError,
        'Please mixin a pagination extension.'
      )
    end

    def filter_records(records)
      records = simple_search(records)
      # records = composite_search(records)
      records
    end

    def simple_search(records)
      return records unless (params['search'].present?)
      search_val = params['search']['value'] != 'value' ? params['search']['value'].present? : JSON.parse(params['search'])['value'].present?
      return records unless search_val
      if params['search']['value'] != 'value'
        val = params['search']['value']
      else
        val = JSON.parse(params['search'])['value']
      end
      conditions = build_conditions_for(val)
      records = records.where(conditions) if conditions
      records
    end

    def composite_search(records)
      conditions = aggregate_query
      records = records.where(conditions) if conditions
      records
    end

    def build_conditions_for(query)
      search_for = query.split(' ')
      criteria = search_for.inject([]) do |criteria, atom|
        criteria << searchable_columns.map { |col| search_condition(col, atom) }.reduce(:or)
      end.reduce(:and)
      criteria
    end

    def search_condition(column, value)
      if column[0] == column.downcase[0]

        ::AjaxDatatablesRails::Base.deprecated '[DEPRECATED] Using table_name.column_name notation is deprecated. Please refer to: https://github.com/antillas21/ajax-datatables-rails#searchable-and-sortable-columns-syntax'
        return deprecated_search_condition(column, value)
      else
        return new_search_condition(column, value)
      end
    end

    def new_search_condition(column, value)
      model, column = column.split('.')
      model = model.constantize
      casted_column = ::Arel::Nodes::NamedFunction.new('CAST', [model.arel_table[column.to_sym].as(typecast)])
      casted_column.matches("%#{sanitize_sql_like(value)}%")
    end

    def deprecated_search_condition(column, value)
      model, column = column.split('.')
      model = model.singularize.titleize.gsub( / /, '' ).constantize

      casted_column = ::Arel::Nodes::NamedFunction.new('CAST', [model.arel_table[column.to_sym].as(typecast)])
      casted_column.matches("%#{sanitize_sql_like(value)}%")
    end

    def aggregate_query
      conditions = searchable_columns.each_with_index.map do |column, index|
        if params[:columns].is_a? String
          value = JSON.parse(params[:columns])[index]["search"]["value"] if params[:columns]
          search_condition(column, value) unless value.blank?
        else
          value = params[:columns]["#{index}"][:search][:value] if params[:columns]
          search_condition(column, value) unless value.blank?
        end

      end
      conditions.compact.reduce(:and)
    end

    def typecast
      case config.db_adapter
      when :oracle then 'VARCHAR2(4000)'
      when :pg then 'VARCHAR'
      when :mysql2 then 'CHAR'
      when :sqlite3 then 'TEXT'
      end
    end

    def offset
      (page - 1) * per_page
    end

    def page
      (params[:start].to_i / per_page) + 1
    end

    def per_page
      params.fetch(:length, 10).to_i
    end

    def sort_column(item)
      new_sort_column(item)
    rescue
      ::AjaxDatatablesRails::Base.deprecated '[DEPRECATED] Using table_name.column_name notation is deprecated. Please refer to: https://github.com/antillas21/ajax-datatables-rails#searchable-and-sortable-columns-syntax'
      deprecated_sort_column(item)
    end

    def deprecated_sort_column(item)
        sortable_columns[sortable_displayed_columns.index(item[:column].to_s)]
    end

    def new_sort_column(item)
      if view_columns != []
        source = view_columns[sortable_displayed_columns[item['column'].to_i].to_sym][:source]
        model, column = source.split('.')
        col = !column.blank? ? [model.constantize.table_name, column].join('.') : source
      else
        model, column = if sortable_displayed_columns[item['column'].to_i].is_integer?
          sortable_columns[sortable_displayed_columns[item['column'].to_i].to_i].split('.')
        else
          sortable_columns[Hash[sortable_columns.map.with_index.to_a][sortable_displayed_columns[item['column'].to_i]].to_i].split('.')
        end
        col = !column.blank? ? [model.constantize.table_name, column].join('.') : model #case for when sort is a virtual column
        col
      end
    end

    def sort_direction(item)
      options = %w(desc asc)
      options.include?(item['dir']) ? item['dir'].upcase : 'ASC'
    end

    def sortable_displayed_columns
      @sortable_displayed_columns ||= generate_sortable_displayed_columns
    end

    def generate_sortable_displayed_columns
      @sortable_displayed_columns = []
      if params[:columns].is_a?(String)
        JSON.parse(params[:columns]).each do |column|
          @sortable_displayed_columns << column['data']
        end
      else
        params[:columns].each_value do |column|
          @sortable_displayed_columns << column[:data]
        end
      end
      @sortable_displayed_columns
    end


    def load_paginator
      case config.paginator
      when :kaminari
        extend Extensions::Kaminari
      when :will_paginate
        extend Extensions::WillPaginate
      else
        extend Extensions::SimplePaginator
      end
      self
    end
  end
end

class String
  def is_integer?
    self.to_i.to_s == self
  end
end
