class AliasAndImplicationImporter
  class Error < RuntimeError; end
  attr_accessor :text, :commands, :forum_id, :rename_aliased_pages, :skip_secondary_validations

  def initialize(text, forum_id, rename_aliased_pages = "0", skip_secondary_validations = true)
    @forum_id = forum_id
    @text = text
    @rename_aliased_pages = rename_aliased_pages
    @skip_secondary_validations = skip_secondary_validations
  end

  def process!(approver = CurrentUser.user)
    tokens = AliasAndImplicationImporter.tokenize(text)
    parse(tokens, approver)
  end

  def validate!
    tokens = AliasAndImplicationImporter.tokenize(text)
    validate(tokens)
  end

  def rename_aliased_pages?
    @rename_aliased_pages == "1"
  end

  def self.tokenize(text)
    text.split(/\r\n|\r|\n/).reject(&:blank?).map do |line|
      line = line.gsub(/[[:space:]]+/, " ").strip

      if line =~ /^(?:create alias|aliasing|alias) (\S+) -> (\S+)$/i
        [:create_alias, $1, $2]

      elsif line =~ /^(?:create implication|implicating|implicate|imply) (\S+) -> (\S+)$/i
        [:create_implication, $1, $2]

      elsif line =~ /^(?:remove alias|unaliasing|unalias) (\S+) -> (\S+)$/i
        [:remove_alias, $1, $2]

      elsif line =~ /^(?:remove implication|unimplicating|unimplicate|unimply) (\S+) -> (\S+)$/i
        [:remove_implication, $1, $2]

      elsif line =~ /^(?:mass update|updating|update|change) (.+?) -> (.*)$/i
        [:mass_update, $1, $2]

      elsif line =~ /^category (\S+) -> (#{Tag.categories.regexp})/
        [:change_category, $1, $2]

      elsif line.strip.empty?
        # do nothing

      else
        raise Error, "Unparseable line: #{line}"
      end
    end
  end

  def validate(tokens)
    tokens.map do |token|
      case token[0]
      when :create_alias
        tag_alias = TagAlias.new(:forum_topic_id => forum_id, :status => "pending", :antecedent_name => token[1], :consequent_name => token[2], :skip_secondary_validations => skip_secondary_validations)
        unless tag_alias.valid?
          raise Error, "Error: #{tag_alias.errors.full_messages.join("; ")} (create alias #{tag_alias.antecedent_name} -> #{tag_alias.consequent_name})"
        end

      when :create_implication
        tag_implication = TagImplication.new(:forum_topic_id => forum_id, :status => "pending", :antecedent_name => token[1], :consequent_name => token[2], :skip_secondary_validations => skip_secondary_validations)
        unless tag_implication.valid?
          raise Error, "Error: #{tag_implication.errors.full_messages.join("; ")} (create implication #{tag_implication.antecedent_name} -> #{tag_implication.consequent_name})"
        end

      when :remove_alias, :remove_implication, :mass_update, :change_category
        # okay

      else
        raise Error, "Unknown token: #{token[0]}"
      end
    end
  end

  def estimate_update_count
    tokens = self.class.tokenize(text)
    tokens.inject(0) do |sum, token|
      case token[0]
      when :create_alias
        sum + TagAlias.new(antecedent_name: token[1], consequent_name: token[2]).estimate_update_count

      when :create_implication
        sum + TagImplication.new(antecedent_name: token[1], consequent_name: token[2]).estimate_update_count

      when :mass_update
        sum + TagBatchChangeJob.estimate_update_count(token[1], token[2])

      when :change_category
        sum + Tag.find_by_name(token[1]).try(:post_count) || 0

      else
        sum + 0
      end
    end
  end

  def affected_tags
    tokens = self.class.tokenize(text)
    tokens.inject([]) do |all, token|
      case token[0]
      when :create_alias, :remove_alias, :create_implication, :remove_implication
        all << token[1]
        all << token[2]
        all

      when :mass_update
        all += Tag.scan_tags(token[1])
        all += Tag.scan_tags(token[2])
        all

      when :change_category
        all << token[1]
        all

      else
        all
      end
    end
  end

private

  def parse(tokens, approver)
    ActiveRecord::Base.transaction do
      tokens.map do |token|
        case token[0]
        when :create_alias
          tag_alias = TagAlias.create(:forum_topic_id => forum_id, :status => "pending", :antecedent_name => token[1], :consequent_name => token[2], :skip_secondary_validations => skip_secondary_validations)
          unless tag_alias.valid?
            raise Error, "Error: #{tag_alias.errors.full_messages.join("; ")} (create alias #{tag_alias.antecedent_name} -> #{tag_alias.consequent_name})"
          end
          tag_alias.rename_wiki_and_artist if rename_aliased_pages?
          tag_alias.approve!(approver: approver, update_topic: false)

        when :create_implication
          tag_implication = TagImplication.create(:forum_topic_id => forum_id, :status => "pending", :antecedent_name => token[1], :consequent_name => token[2], :skip_secondary_validations => skip_secondary_validations)
          unless tag_implication.valid?
            raise Error, "Error: #{tag_implication.errors.full_messages.join("; ")} (create implication #{tag_implication.antecedent_name} -> #{tag_implication.consequent_name})"
          end
          tag_implication.approve!(approver: approver, update_topic: false)

        when :remove_alias
          tag_alias = TagAlias.active.find_by(antecedent_name: token[1], consequent_name: token[2])
          raise Error, "Alias for #{token[1]} not found" if tag_alias.nil?
          tag_alias.reject!(update_topic: false)

        when :remove_implication
          tag_implication = TagImplication.active.find_by(antecedent_name: token[1], consequent_name: token[2])
          raise Error, "Implication for #{token[1]} not found" if tag_implication.nil?
          tag_implication.reject!(update_topic: false)

        when :mass_update
          TagBatchChangeJob.perform_later(token[1], token[2], CurrentUser.user, CurrentUser.ip_addr)

        when :change_category
          tag = Tag.find_by_name(token[1])
          tag.category = Tag.categories.value_for(token[2])
          tag.save

        else
          raise Error, "Unknown token: #{token[0]}"
        end
      end
    end
  end
end
