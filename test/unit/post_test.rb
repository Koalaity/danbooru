require 'test_helper'

class PostTest < ActiveSupport::TestCase
  def assert_tag_match(posts, query)
    assert_equal(posts.map(&:id), Post.tag_match(query).pluck(:id))
  end

  def self.assert_invalid_tag(tag_name)
    should "not allow '#{tag_name}' to be tagged" do
      post = build(:post, tag_string: "touhou #{tag_name}")

      assert(post.valid?)
      assert_equal("touhou", post.tag_string)
      assert_equal(1, post.warnings[:base].grep(/Couldn't add tag/).count)
    end
  end

  def setup
    super

    travel_to(2.weeks.ago) do
      @user = FactoryBot.create(:user)
    end
    CurrentUser.user = @user
    CurrentUser.ip_addr = "127.0.0.1"
    mock_saved_search_service!
    mock_pool_archive_service!
  end

  def teardown
    super

    CurrentUser.user = nil
    CurrentUser.ip_addr = nil
  end

  context "Deletion:" do
    context "Expunging a post" do
      setup do
        Delayed::Worker.delay_jobs = true
        @upload = UploadService.new(FactoryBot.attributes_for(:jpg_upload)).start!
        @post = @upload.post
        Favorite.add(post: @post, user: @user)
        create(:favorite_group).add!(@post.id)
      end

      teardown do
        Delayed::Worker.delay_jobs = false
      end

      should "delete the files" do
        assert_nothing_raised { @post.file(:preview) }
        assert_nothing_raised { @post.file(:original) }

        @post.expunge!

        assert_raise(StandardError) { @post.file(:preview) }
        assert_raise(StandardError) { @post.file(:original) }
      end

      should "remove all favorites" do
        @post.expunge!

        assert_equal(0, Favorite.for_user(@user.id).where("post_id = ?", @post.id).count)
      end

      should "remove all favgroups" do
        assert_equal(1, FavoriteGroup.for_post(@post.id).count)
        @post.expunge!
        assert_equal(0, FavoriteGroup.for_post(@post.id).count)
      end

      should "decrement the uploader's upload count" do
        assert_difference("@post.uploader.reload.post_upload_count", -1) do
          @post.expunge!
        end
      end

      should "decrement the user's note update count" do
        FactoryBot.create(:note, post: @post)
        assert_difference(["@post.uploader.reload.note_update_count"], -1) do
          @post.expunge!
        end
      end

      should "decrement the user's post update count" do
        assert_difference(["@post.uploader.reload.post_update_count"], -1) do
          @post.expunge!
        end
      end

      should "decrement the user's favorite count" do
        assert_difference(["@post.uploader.reload.favorite_count"], -1) do
          @post.expunge!
        end
      end

      should "remove the post from iqdb" do
        mock_iqdb_service!
        Post.iqdb_sqs_service.expects(:send_message).with("remove\n#{@post.id}")

        @post.expunge!
      end

      context "that is status locked" do
        setup do
          @post.update(is_status_locked: true)
        end

        should "not destroy the record" do
          @post.expunge!
          assert_equal(1, Post.where("id = ?", @post.id).count)
        end
      end

      context "that belongs to a pool" do
        setup do
          # must be a builder to update deleted pools. must be >1 week old to remove posts from pools.
          CurrentUser.user = FactoryBot.create(:builder_user, created_at: 1.month.ago)

          SqsService.any_instance.stubs(:send_message)
          @pool = FactoryBot.create(:pool)
          @pool.add!(@post)

          @deleted_pool = FactoryBot.create(:pool)
          @deleted_pool.add!(@post)
          @deleted_pool.update_columns(is_deleted: true)

          @post.expunge!
          @pool.reload
          @deleted_pool.reload
        end

        should "remove the post from all pools" do
          assert_equal([], @pool.post_ids)
        end

        should "remove the post from deleted pools" do
          assert_equal([], @deleted_pool.post_ids)
        end

        should "destroy the record" do
          assert_equal([], @post.errors.full_messages)
          assert_equal(0, Post.where("id = ?", @post.id).count)
        end
      end
    end

    context "Deleting a post" do
      setup do
        Danbooru.config.stubs(:blank_tag_search_fast_count).returns(nil)
      end

      context "that is status locked" do
        setup do
          @post = FactoryBot.create(:post, is_status_locked: true)
        end

        should "fail" do
          @post.delete!("test")
          assert_equal(["Is status locked ; cannot delete post"], @post.errors.full_messages)
          assert_equal(1, Post.where("id = ?", @post.id).count)
        end
      end

      context "that is pending" do
        setup do
          @post = FactoryBot.create(:post, is_pending: true)
        end

        should "succeed" do
          @post.delete!("test")

          assert_equal(true, @post.is_deleted)
          assert_equal(1, @post.flags.size)
          assert_match(/test/, @post.flags.last.reason)
        end
      end

      context "with the banned_artist tag" do
        should "also ban the post" do
          post = FactoryBot.create(:post, :tag_string => "banned_artist")
          post.delete!("test")
          post.reload
          assert(post.is_banned?)
        end
      end

      context "that is still in cooldown after being flagged" do
        should "succeed" do
          post = FactoryBot.create(:post)
          post.flag!("test flag")
          post.delete!("test deletion")

          assert_equal(true, post.is_deleted)
          assert_equal(2, post.flags.size)
        end
      end

      should "toggle the is_deleted flag" do
        post = FactoryBot.create(:post)
        assert_equal(false, post.is_deleted?)
        post.delete!("test")
        assert_equal(true, post.is_deleted?)
      end
    end
  end

  context "Parenting:" do
    context "Assigning a parent to a post" do
      should "update the has_children flag on the parent" do
        p1 = FactoryBot.create(:post)
        assert(!p1.has_children?, "Parent should not have any children")
        c1 = FactoryBot.create(:post, :parent_id => p1.id)
        p1.reload
        assert(p1.has_children?, "Parent not updated after child was added")
      end

      should "update the has_children flag on the old parent" do
        p1 = FactoryBot.create(:post)
        p2 = FactoryBot.create(:post)
        c1 = FactoryBot.create(:post, :parent_id => p1.id)
        c1.parent_id = p2.id
        c1.save
        p1.reload
        p2.reload
        assert(!p1.has_children?, "Old parent should not have a child")
        assert(p2.has_children?, "New parent should have a child")
      end
    end

    context "Expunging a post with" do
      context "a parent" do
        should "reset the has_children flag of the parent" do
          p1 = FactoryBot.create(:post)
          c1 = FactoryBot.create(:post, :parent_id => p1.id)
          c1.expunge!
          p1.reload
          assert_equal(false, p1.has_children?)
        end

        should "reassign favorites to the parent" do
          p1 = FactoryBot.create(:post)
          c1 = FactoryBot.create(:post, :parent_id => p1.id)
          user = FactoryBot.create(:user)
          c1.add_favorite!(user)
          c1.expunge!
          p1.reload
          assert(!Favorite.exists?(:post_id => c1.id, :user_id => user.id))
          assert(Favorite.exists?(:post_id => p1.id, :user_id => user.id))
          assert_equal(0, c1.score)
        end

        should "update the parent's has_children flag" do
          p1 = FactoryBot.create(:post)
          c1 = FactoryBot.create(:post, :parent_id => p1.id)
          c1.expunge!
          p1.reload
          assert(!p1.has_children?, "Parent should not have children")
        end
      end

      context "one child" do
        should "remove the parent of that child" do
          p1 = FactoryBot.create(:post)
          c1 = FactoryBot.create(:post, :parent_id => p1.id)
          p1.expunge!
          c1.reload
          assert_nil(c1.parent)
        end
      end

      context "two or more children" do
        setup do
          # ensure initial post versions won't be merged.
          travel_to(1.day.ago) do
            @p1 = FactoryBot.create(:post)
            @c1 = FactoryBot.create(:post, :parent_id => @p1.id)
            @c2 = FactoryBot.create(:post, :parent_id => @p1.id)
            @c3 = FactoryBot.create(:post, :parent_id => @p1.id)
          end
        end

        should "reparent all children to the first child" do
          @p1.expunge!
          @c1.reload
          @c2.reload
          @c3.reload

          assert_nil(@c1.parent_id)
          assert_equal(@c1.id, @c2.parent_id)
          assert_equal(@c1.id, @c3.parent_id)
        end

        should "save a post version record for each child" do
          assert_difference(["@c1.versions.count", "@c2.versions.count", "@c3.versions.count"]) do
            @p1.expunge!
            @c1.reload
            @c2.reload
            @c3.reload
          end
        end

        should "set the has_children flag on the new parent" do
          @p1.expunge!
          assert_equal(true, @c1.reload.has_children?)
        end
      end
    end
    
    context "Deleting a post with" do
      context "a parent" do
        should "not reassign favorites to the parent by default" do
          p1 = FactoryBot.create(:post)
          c1 = FactoryBot.create(:post, :parent_id => p1.id)
          user = FactoryBot.create(:gold_user)
          c1.add_favorite!(user)
          c1.delete!("test")
          p1.reload
          assert(Favorite.exists?(:post_id => c1.id, :user_id => user.id))
          assert(!Favorite.exists?(:post_id => p1.id, :user_id => user.id))
        end

        should "reassign favorites to the parent if specified" do
          p1 = FactoryBot.create(:post)
          c1 = FactoryBot.create(:post, :parent_id => p1.id)
          user = FactoryBot.create(:gold_user)
          c1.add_favorite!(user)
          c1.delete!("test", :move_favorites => true)
          p1.reload
          assert(!Favorite.exists?(:post_id => c1.id, :user_id => user.id), "Child should not still have favorites")
          assert(Favorite.exists?(:post_id => p1.id, :user_id => user.id), "Parent should have favorites")
        end

        should "not update the parent's has_children flag" do
          p1 = FactoryBot.create(:post)
          c1 = FactoryBot.create(:post, :parent_id => p1.id)
          c1.delete!("test")
          p1.reload
          assert(p1.has_children?, "Parent should have children")
        end

        should "clear the has_active_children flag when the 'move favorites' option is set" do
          user = FactoryBot.create(:gold_user)
          p1 = FactoryBot.create(:post)
          c1 = FactoryBot.create(:post, :parent_id => p1.id)
          c1.add_favorite!(user)

          assert_equal(true, p1.reload.has_active_children?)
          c1.delete!("test", :move_favorites => true)
          assert_equal(false, p1.reload.has_active_children?)
        end
      end

      context "one child" do
        should "not remove the has_children flag" do
          p1 = FactoryBot.create(:post)
          c1 = FactoryBot.create(:post, :parent_id => p1.id)
          p1.delete!("test")
          p1.reload
          assert_equal(true, p1.has_children?)
        end

        should "not remove the parent of that child" do
          p1 = FactoryBot.create(:post)
          c1 = FactoryBot.create(:post, :parent_id => p1.id)
          p1.delete!("test")
          c1.reload
          assert_not_nil(c1.parent)
        end
      end

      context "two or more children" do
        should "not reparent all children to the first child" do
          p1 = FactoryBot.create(:post)
          c1 = FactoryBot.create(:post, :parent_id => p1.id)
          c2 = FactoryBot.create(:post, :parent_id => p1.id)
          c3 = FactoryBot.create(:post, :parent_id => p1.id)
          p1.delete!("test")
          c1.reload
          c2.reload
          c3.reload
          assert_equal(p1.id, c1.parent_id)
          assert_equal(p1.id, c2.parent_id)
          assert_equal(p1.id, c3.parent_id)
        end
      end
    end

    context "Undeleting a post with a parent" do
      should "update with a new approver" do
        new_user = FactoryBot.create(:moderator_user)
        p1 = FactoryBot.create(:post)
        c1 = FactoryBot.create(:post, :parent_id => p1.id)
        c1.delete!("test")
        CurrentUser.scoped(new_user, "127.0.0.1") do
          c1.undelete!
        end
        p1.reload
        assert_equal(new_user.id, c1.approver_id)
      end

      should "preserve the parent's has_children flag" do
        p1 = FactoryBot.create(:post)
        c1 = FactoryBot.create(:post, :parent_id => p1.id)
        c1.delete!("test")
        c1.undelete!
        p1.reload
        assert_not_nil(c1.parent_id)
        assert(p1.has_children?, "Parent should have children")
      end
    end
  end

  context "Moderation:" do
    context "A deleted post" do
      setup do
        @post = FactoryBot.create(:post, :is_deleted => true)
      end

      context "that is status locked" do
        setup do
          @post.update(is_status_locked: true)
        end

        should "not allow undeletion" do
          @post.undelete!
          assert_equal(["Is status locked ; cannot undelete post"], @post.errors.full_messages)
          assert_equal(true, @post.is_deleted?)
        end
      end

      context "that is undeleted" do
        setup do
          @mod = FactoryBot.create(:moderator_user)
          CurrentUser.user = @mod
        end

        context "by the approver" do
          setup do
            @post.update_attribute(:approver_id, @mod.id)
          end

          should "not be permitted" do
            assert_raises(::Post::ApprovalError) do
              @post.undelete!
            end
          end
        end

        context "by the uploader" do
          setup do
            @post.update_attribute(:uploader_id, @mod.id)
          end

          should "not be permitted" do
            assert_raises(::Post::ApprovalError) do
              @post.undelete!
            end
          end
        end
      end

      context "when undeleted" do
        should "be undeleted" do
          @post.undelete!
          assert_equal(false, @post.reload.is_deleted?)
        end

        should "create a mod action" do
          @post.undelete!
          assert_equal("undeleted post ##{@post.id}", ModAction.last.description)
          assert_equal("post_undelete", ModAction.last.category)
        end
      end

      context "when approved" do
        should "be undeleted" do
          @post.approve!
          assert_equal(false, @post.reload.is_deleted?)
        end

        should "create a mod action" do
          @post.approve!
          assert_equal("undeleted post ##{@post.id}", ModAction.last.description)
          assert_equal("post_undelete", ModAction.last.category)
        end
      end

      should "be appealed" do
        assert_difference("PostAppeal.count", 1) do
          @post.appeal!("xxx")
        end
        assert(@post.is_deleted?, "Post should still be deleted")
        assert_equal(1, @post.appeals.count)
      end
    end

    context "An approved post" do
      should "be flagged" do
        post = FactoryBot.create(:post)
        assert_difference("PostFlag.count", 1) do
          post.flag!("bad")
        end
        assert(post.is_flagged?, "Post should be flagged.")
        assert_equal(1, post.flags.count)
      end

      should "not be flagged if no reason is given" do
        post = FactoryBot.create(:post)
        assert_difference("PostFlag.count", 0) do
          assert_raises(PostFlag::Error) do
            post.flag!("")
          end
        end
      end
    end

    context "An unapproved post" do
      should "preserve the approver's identity when approved" do
        post = FactoryBot.create(:post, :is_pending => true)
        post.approve!
        assert_equal(post.approver_id, CurrentUser.id)
      end

      context "that was previously approved by person X" do
        setup do
          @user = FactoryBot.create(:moderator_user, :name => "xxx")
          @user2 = FactoryBot.create(:moderator_user, :name => "yyy")
          @post = FactoryBot.create(:post, :approver_id => @user.id)
          @post.flag!("bad")
        end

        should "not allow person X to reapprove that post" do
          approval = @post.approve!(@user)
          assert_includes(approval.errors.full_messages, "You have previously approved this post and cannot approve it again")
        end

        should "allow person Y to approve the post" do
          @post.approve!(@user2)
          assert(@post.valid?)
        end
      end

      context "that has been reapproved" do
        should "no longer be flagged or pending" do
          post = FactoryBot.create(:post)
          post.flag!("bad")
          post.approve!
          assert(post.errors.empty?, post.errors.full_messages.join(", "))
          post.reload
          assert_equal(false, post.is_flagged?)
          assert_equal(false, post.is_pending?)
        end
      end
    end

    context "A status locked post" do
      setup do
        @post = FactoryBot.create(:post, is_status_locked: true)
      end

      should "not allow new flags" do
        assert_raises(PostFlag::Error) do
          @post.flag!("wrong")
        end
      end

      should "not allow new appeals" do
        assert_raises(PostAppeal::Error) do
          @post.appeal!("wrong")
        end
      end

      should "not allow approval" do
        approval = @post.approve!
        assert_includes(approval.errors.full_messages, "Post is locked and cannot be approved")
      end
    end
  end

  context "Tagging:" do
    context "A post" do
      setup do
        @post = FactoryBot.create(:post)
      end

      context "as a new user" do
        setup do
          @post.update(:tag_string => "aaa bbb ccc ddd tagme")
          CurrentUser.user = FactoryBot.create(:user)
        end

        should "not allow you to remove tags" do
          @post.update(tag_string: "aaa")
          assert_equal(["You must have an account at least 1 week old to remove tags"], @post.errors.full_messages)
        end

        should "allow you to remove request tags" do
          @post.update(tag_string: "aaa bbb ccc ddd")
          @post.reload
          assert_equal("aaa bbb ccc ddd", @post.tag_string)
        end
      end

      context "with a banned artist" do
        setup do
          CurrentUser.scoped(FactoryBot.create(:admin_user)) do
            @artist = FactoryBot.create(:artist)
            @artist.ban!
          end
          @post = FactoryBot.create(:post, :tag_string => @artist.name)
        end

        should "ban the post" do
          assert_equal(true, @post.is_banned?)
        end
      end

      context "with an artist tag that is then changed to copyright" do
        setup do
          CurrentUser.user = FactoryBot.create(:builder_user)
          @post = Post.find(@post.id)
          @post.update(:tag_string => "art:abc")
          @post = Post.find(@post.id)
          @post.update(:tag_string => "copy:abc")
          @post.reload
        end

        should "update the category of the tag" do
          assert_equal(Tag.categories.copyright, Tag.find_by_name("abc").category)
        end

        should "1234 update the category cache of the tag" do
          assert_equal(Tag.categories.copyright, Cache.get("tc:#{Cache.hash('abc')}"))
        end

        should "update the tag counts of the posts" do
          assert_equal(0, @post.tag_count_artist)
          assert_equal(1, @post.tag_count_copyright)
          assert_equal(0, @post.tag_count_general)
        end
      end

      context "using a tag prefix on an aliased tag" do
        setup do
          FactoryBot.create(:tag_alias, :antecedent_name => "abc", :consequent_name => "xyz")
          @post = Post.find(@post.id)
          @post.update(:tag_string => "art:abc")
          @post.reload
        end

        should "convert the tag to its normalized version" do
          assert_equal("xyz", @post.tag_string)
        end
      end

      context "tagged with a valid tag" do
        subject { @post }

        should allow_value("touhou 100%").for(:tag_string)
        should allow_value("touhou FOO").for(:tag_string)
        should allow_value("touhou -foo").for(:tag_string)
        should allow_value("touhou pool:foo").for(:tag_string)
        should allow_value("touhou -pool:foo").for(:tag_string)
        should allow_value("touhou newpool:foo").for(:tag_string)
        should allow_value("touhou fav:self").for(:tag_string)
        should allow_value("touhou -fav:self").for(:tag_string)
        should allow_value("touhou upvote:self").for(:tag_string)
        should allow_value("touhou downvote:self").for(:tag_string)
        should allow_value("touhou parent:1").for(:tag_string)
        should allow_value("touhou child:1").for(:tag_string)
        should allow_value("touhou source:foo").for(:tag_string)
        should allow_value("touhou rating:z").for(:tag_string)
        should allow_value("touhou locked:rating").for(:tag_string)
        should allow_value("touhou -locked:rating").for(:tag_string)

        # \u3000 = ideographic space, \u00A0 = no-break space
        should allow_value("touhou\u3000foo").for(:tag_string)
        should allow_value("touhou\u00A0foo").for(:tag_string)
      end

      context "tagged with an invalid tag" do
        context "that doesn't already exist" do
          assert_invalid_tag("user:evazion")
          assert_invalid_tag("*~foo")
          assert_invalid_tag("*-foo")
          assert_invalid_tag(",-foo")

          assert_invalid_tag("___")
          assert_invalid_tag("~foo")
          assert_invalid_tag("_foo")
          assert_invalid_tag("foo_")
          assert_invalid_tag("foo__bar")
          assert_invalid_tag("foo*bar")
          assert_invalid_tag("foo,bar")
          assert_invalid_tag("foo\abar")
          assert_invalid_tag("café")
          assert_invalid_tag("東方")
        end

        context "that already exists" do
          setup do
            %W(___ ~foo _foo foo_ foo__bar foo*bar foo,bar foo\abar café 東方).each do |tag|
              build(:tag, name: tag).save(validate: false)
            end
          end

          assert_invalid_tag("___")
          assert_invalid_tag("~foo")
          assert_invalid_tag("_foo")
          assert_invalid_tag("foo_")
          assert_invalid_tag("foo__bar")
          assert_invalid_tag("foo*bar")
          assert_invalid_tag("foo,bar")
          assert_invalid_tag("foo\abar")
          assert_invalid_tag("café")
          assert_invalid_tag("東方")
        end
      end

      context "tagged with a metatag" do

        context "for typing a tag" do
          setup do
            @post = FactoryBot.create(:post, tag_string: "char:hoge")
            @tags = @post.tag_array
          end

          should "change the type" do
            assert(Tag.where(name: "hoge", category: 4).exists?, "expected 'moge' tag to be created as a character")
          end
        end

        context "for typing an aliased tag" do
          setup do
            @alias = FactoryBot.create(:tag_alias, antecedent_name: "hoge", consequent_name: "moge")
            @post = FactoryBot.create(:post, tag_string: "char:hoge")
            @tags = @post.tag_array
          end

          should "change the type" do
            assert_equal(["moge"], @tags)
            assert(Tag.where(name: "moge", category: 0).exists?, "expected 'moge' tag to be created as a character")
            assert(Tag.where(name: "hoge", category: 4).exists?, "expected 'moge' tag to be created as a character")
          end
        end

        context "for a wildcard implication" do
          setup do
            @post = FactoryBot.create(:post, tag_string: "char:someone_(cosplay) test_school_uniform")
            @tags = @post.tag_array
          end

          should "add the cosplay tag" do
            assert(@tags.include?("cosplay"))
          end

          should "add the school_uniform tag" do
            assert(@tags.include?("school_uniform"))
          end

          should "create the tag" do
            assert(Tag.where(name: "someone_(cosplay)").exists?, "expected 'someone_(cosplay)' tag to be created")
            assert(Tag.where(name: "someone_(cosplay)", category: 4).exists?, "expected 'someone_(cosplay)' tag to be created as character")
            assert(Tag.where(name: "someone", category: 4).exists?, "expected 'someone' tag to be created")
            assert(Tag.where(name: "school_uniform", category: 0).exists?, "expected 'school_uniform' tag to be created")
          end

          should "apply aliases when the character tag is added" do
            FactoryBot.create(:tag, name: "jim", category: Tag.categories.general)
            FactoryBot.create(:tag, name: "james", category: Tag.categories.character)
            FactoryBot.create(:tag_alias, antecedent_name: "jim", consequent_name: "james")

            @post.add_tag("jim_(cosplay)")
            @post.save

            assert(@post.has_tag?("james"), "expected 'jim' to be aliased to 'james'")
          end

          should "apply implications after the character tag is added" do
            FactoryBot.create(:tag, name: "jimmy", category: Tag.categories.character)
            FactoryBot.create(:tag, name: "jim", category: Tag.categories.character)
            FactoryBot.create(:tag_implication, antecedent_name: "jimmy", consequent_name: "jim")
            @post.add_tag("jimmy_(cosplay)")
            @post.save

            assert(@post.has_tag?("jim"), "expected 'jimmy' to imply 'jim'")
          end
        end

        context "for a parent" do
          setup do
            @parent = FactoryBot.create(:post)
          end

          should "update the parent relationships for both posts" do
            @post.update(tag_string: "aaa parent:#{@parent.id}")
            @post.reload
            @parent.reload
            assert_equal(@parent.id, @post.parent_id)
            assert(@parent.has_children?)
          end

          should "not allow self-parenting" do
            @post.update(:tag_string => "parent:#{@post.id}")
            assert_nil(@post.parent_id)
          end

          should "clear the parent with parent:none" do
            @post.update(:parent_id => @parent.id)
            assert_equal(@parent.id, @post.parent_id)

            @post.update(:tag_string => "parent:none")
            assert_nil(@post.parent_id)
          end

          should "clear the parent with -parent:1234" do
            @post.update(:parent_id => @parent.id)
            assert_equal(@parent.id, @post.parent_id)

            @post.update(:tag_string => "-parent:#{@parent.id}")
            assert_nil(@post.parent_id)
          end
        end

        context "for a favgroup" do
          setup do
            @favgroup = FactoryBot.create(:favorite_group, creator: @user)
            @post = FactoryBot.create(:post, :tag_string => "aaa favgroup:#{@favgroup.id}")
          end

          should "add the post to the favgroup" do
            assert_equal(1, @favgroup.reload.post_count)
            assert_equal(true, !!@favgroup.contains?(@post.id))
          end

          should "remove the post from the favgroup" do
            @post.update(:tag_string => "-favgroup:#{@favgroup.id}")

            assert_equal(0, @favgroup.reload.post_count)
            assert_equal(false, !!@favgroup.contains?(@post.id))
          end
        end

        context "for a pool" do
          setup do
            mock_pool_archive_service!
            start_pool_archive_transaction
          end

          teardown do
            rollback_pool_archive_transaction
          end

          context "on creation" do
            setup do
              @pool = FactoryBot.create(:pool)
              @post = FactoryBot.create(:post, :tag_string => "aaa pool:#{@pool.id}")
            end

            should "add the post to the pool" do
              @post.reload
              @pool.reload
              assert_equal([@post.id], @pool.post_ids)
              assert_equal("pool:#{@pool.id} pool:series", @post.pool_string)
            end
          end

          context "negated" do
            setup do
              @pool = FactoryBot.create(:pool)
              @post = FactoryBot.create(:post, :tag_string => "aaa")
              @post.add_pool!(@pool)
              @post.tag_string = "aaa -pool:#{@pool.id}"
              @post.save
            end

            should "remove the post from the pool" do
              @post.reload
              @pool.reload
              assert_equal([], @pool.post_ids)
              assert_equal("", @post.pool_string)
            end
          end

          context "id" do
            setup do
              @pool = FactoryBot.create(:pool)
              @post.update(tag_string: "aaa pool:#{@pool.id}")
            end

            should "add the post to the pool" do
              @post.reload
              @pool.reload
              assert_equal([@post.id], @pool.post_ids)
              assert_equal("pool:#{@pool.id} pool:series", @post.pool_string)
            end
          end

          context "name" do
            context "that exists" do
              setup do
                @pool = FactoryBot.create(:pool, :name => "abc")
                @post.update(tag_string: "aaa pool:abc")
              end

              should "add the post to the pool" do
                @post.reload
                @pool.reload
                assert_equal([@post.id], @pool.post_ids)
                assert_equal("pool:#{@pool.id} pool:series", @post.pool_string)
              end
            end

            context "that doesn't exist" do
              should "create a new pool and add the post to that pool" do
                @post.update(tag_string: "aaa newpool:abc")
                @pool = Pool.find_by_name("abc")
                @post.reload
                assert_not_nil(@pool)
                assert_equal([@post.id], @pool.post_ids)
                assert_equal("pool:#{@pool.id} pool:series", @post.pool_string)
              end
            end

            context "with special characters" do
              should "not strip '%' from the name" do
                @post.update(tag_string: "aaa newpool:ichigo_100%")
                assert(Pool.exists?(name: "ichigo_100%"))
              end
            end
          end
        end

        context "for a rating" do
          context "that is valid" do
            should "update the rating if the post is unlocked" do
              @post.update(tag_string: "aaa rating:e")
              @post.reload
              assert_equal("e", @post.rating)
            end
          end

          context "that is invalid" do
            should "not update the rating" do
              @post.update(tag_string: "aaa rating:z")
              @post.reload
              assert_equal("q", @post.rating)
            end
          end

          context "that is locked" do
            should "change the rating if locked in the same update" do
              @post.update(tag_string: "rating:e", is_rating_locked: true)

              assert(@post.valid?)
              assert_equal("e", @post.reload.rating)
            end

            should "not change the rating if locked previously" do
              @post.is_rating_locked = true
              @post.save

              @post.update(:tag_string => "rating:e")

              assert(@post.invalid?)
              assert_not_equal("e", @post.reload.rating)
            end
          end
        end

        context "for a fav" do
          should "add/remove the current user to the post's favorite listing" do
            @post.update(tag_string: "aaa fav:self")
            assert_equal("fav:#{@user.id}", @post.fav_string)

            @post.update(tag_string: "aaa -fav:self")
            assert_equal("", @post.fav_string)
          end
        end

        context "for a child" do
          should "add and remove children" do
            @children = FactoryBot.create_list(:post, 3, parent_id: nil)

            @post.update(tag_string: "aaa child:#{@children.first.id}..#{@children.last.id}")
            assert_equal(true, @post.reload.has_children?)
            assert_equal(@post.id, @children[0].reload.parent_id)
            assert_equal(@post.id, @children[1].reload.parent_id)
            assert_equal(@post.id, @children[2].reload.parent_id)

            @post.update(tag_string: "aaa -child:#{@children.first.id}")
            assert_equal(true, @post.reload.has_children?)
            assert_nil(@children[0].reload.parent_id)
            assert_equal(@post.id, @children[1].reload.parent_id)
            assert_equal(@post.id, @children[2].reload.parent_id)

            @post.update(tag_string: "aaa child:none")
            assert_equal(false, @post.reload.has_children?)
            assert_nil(@children[0].reload.parent_id)
            assert_nil(@children[1].reload.parent_id)
            assert_nil(@children[2].reload.parent_id)
          end
        end

        context "for a source" do
          should "set the source with source:foo_bar_baz" do
            @post.update(:tag_string => "source:foo_bar_baz")
            assert_equal("foo_bar_baz", @post.source)
          end

          should 'set the source with source:"foo bar baz"' do
            @post.update(:tag_string => 'source:"foo bar baz"')
            assert_equal("foo bar baz", @post.source)
          end

          should 'strip the source with source:"  foo bar baz  "' do
            @post.update(:tag_string => 'source:"  foo bar baz  "')
            assert_equal("foo bar baz", @post.source)
          end

          should "clear the source with source:none" do
            @post.update(:source => "foobar")
            @post.update(:tag_string => "source:none")
            assert_equal("", @post.source)
          end

          should "set the pixiv id with source:https://img18.pixiv.net/img/evazion/14901720.png" do
            @post.update(:tag_string => "source:https://img18.pixiv.net/img/evazion/14901720.png")
            assert_equal(14901720, @post.pixiv_id)
          end
        end

        context "of" do
          setup do
            @builder = FactoryBot.create(:builder_user)
          end

          context "locked:notes" do
            context "by a member" do
              should "not lock the notes" do
                @post.update(:tag_string => "locked:notes")
                assert_equal(false, @post.is_note_locked)
              end
            end

            context "by a builder" do
              should "lock/unlock the notes" do
                CurrentUser.scoped(@builder) do
                  @post.update(:tag_string => "locked:notes")
                  assert_equal(true, @post.is_note_locked)

                  @post.update(:tag_string => "-locked:notes")
                  assert_equal(false, @post.is_note_locked)
                end
              end
            end
          end

          context "locked:rating" do
            context "by a member" do
              should "not lock the rating" do
                @post.update(:tag_string => "locked:rating")
                assert_equal(false, @post.is_rating_locked)
              end
            end

            context "by a builder" do
              should "lock/unlock the rating" do
                CurrentUser.scoped(@builder) do
                  @post.update(:tag_string => "locked:rating")
                  assert_equal(true, @post.is_rating_locked)

                  @post.update(:tag_string => "-locked:rating")
                  assert_equal(false, @post.is_rating_locked)
                end
              end
            end
          end

          context "locked:status" do
            context "by a member" do
              should "not lock the status" do
                @post.update(:tag_string => "locked:status")
                assert_equal(false, @post.is_status_locked)
              end
            end

            context "by an admin" do
              should "lock/unlock the status" do
                CurrentUser.scoped(FactoryBot.create(:admin_user)) do
                  @post.update(:tag_string => "locked:status")
                  assert_equal(true, @post.is_status_locked)

                  @post.update(:tag_string => "-locked:status")
                  assert_equal(false, @post.is_status_locked)
                end
              end
            end
          end
        end

        context "of" do
          setup do
            @gold = FactoryBot.create(:gold_user)
          end

          context "upvote:self or downvote:self" do
            context "by a member" do
              should "not upvote the post" do
                assert_raises PostVote::Error do
                  @post.update(:tag_string => "upvote:self")
                end

                assert_equal(0, @post.score)
              end

              should "not downvote the post" do
                assert_raises PostVote::Error do
                  @post.update(:tag_string => "downvote:self")
                end

                assert_equal(0, @post.score)
              end
            end

            context "by a gold user" do
              should "upvote the post" do
                CurrentUser.scoped(FactoryBot.create(:gold_user)) do
                  @post.update(:tag_string => "tag1 tag2 upvote:self")
                  assert_equal(false, @post.errors.any?)
                  assert_equal(1, @post.score)
                end
              end

              should "downvote the post" do
                CurrentUser.scoped(FactoryBot.create(:gold_user)) do
                  @post.update(:tag_string => "tag1 tag2 downvote:self")
                  assert_equal(false, @post.errors.any?)
                  assert_equal(-1, @post.score)
                end
              end
            end
          end
        end
      end

      context "tagged with a negated tag" do
        should "remove the tag if present" do
          @post.update(tag_string: "aaa bbb ccc")
          @post.update(tag_string: "aaa bbb ccc -bbb")
          @post.reload
          assert_equal("aaa ccc", @post.tag_string)
        end

        should "resolve aliases" do
          FactoryBot.create(:tag_alias, :antecedent_name => "/tr", :consequent_name => "translation_request")
          @post.update(:tag_string => "aaa translation_request -/tr")

          assert_equal("aaa", @post.tag_string)
        end
      end

      context "tagged with animated_gif or animated_png" do
        should "remove the tag if not a gif or png" do
          @post.update(tag_string: "tagme animated_gif")
          assert_equal("tagme", @post.tag_string)

          @post.update(tag_string: "tagme animated_png")
          assert_equal("tagme", @post.tag_string)
        end
      end

      should "have an array representation of its tags" do
        post = FactoryBot.create(:post)
        post.reload
        post.set_tag_string("aaa bbb")
        assert_equal(%w(aaa bbb), post.tag_array)
        assert_equal(%w(tag1 tag2), post.tag_array_was)
      end

      context "with large dimensions" do
        setup do
          @post.image_width = 10_000
          @post.image_height = 10
          @post.tag_string = ""
          @post.save
        end

        should "have the appropriate dimension tags added automatically" do
          assert_match(/incredibly_absurdres/, @post.tag_string)
          assert_match(/absurdres/, @post.tag_string)
          assert_match(/highres/, @post.tag_string)
        end
      end

      context "with a large file size" do
        setup do
          @post.file_size = 11.megabytes
          @post.tag_string = ""
          @post.save
        end

        should "have the appropriate file size tags added automatically" do
          assert_match(/huge_filesize/, @post.tag_string)
        end
      end

      context "with a .zip file extension" do
        setup do
          @post.file_ext = "zip"
          @post.tag_string = ""
          @post.save
        end

        should "have the appropriate file type tag added automatically" do
          assert_match(/ugoira/, @post.tag_string)
        end
      end

      context "with a .webm file extension" do
        setup do
          FactoryBot.create(:tag_implication, antecedent_name: "webm", consequent_name: "animated")
          @post.file_ext = "webm"
          @post.tag_string = ""
          @post.save
        end

        should "have the appropriate file type tag added automatically" do
          assert_match(/webm/, @post.tag_string)
        end

        should "apply implications after adding the file type tag" do
          assert(@post.has_tag?("animated"), "expected 'webm' to imply 'animated'")
        end
      end

      context "with a .swf file extension" do
        setup do
          @post.file_ext = "swf"
          @post.tag_string = ""
          @post.save
        end

        should "have the appropriate file type tag added automatically" do
          assert_match(/flash/, @post.tag_string)
        end
      end

      context "with *_(cosplay) tags" do
        should "add the character tags and the cosplay tag" do
          @post.add_tag("hakurei_reimu_(cosplay)")
          @post.add_tag("hatsune_miku_(cosplay)")
          @post.save

          assert(@post.has_tag?("hakurei_reimu"))
          assert(@post.has_tag?("hatsune_miku"))
          assert(@post.has_tag?("cosplay"))
        end

        should "not add the _(cosplay) tag if it conflicts with an existing tag" do
          create(:tag, name: "little_red_riding_hood", category: Tag.categories.copyright)
          @post = create(:post, tag_string: "little_red_riding_hood_(cosplay)")

          refute(@post.has_tag?("little_red_riding_hood"))
          refute(@post.has_tag?("cosplay"))
          assert(@post.warnings[:base].grep(/Couldn't add tag/).present?)
        end
      end

      context "that has been updated" do
        should "create a new version if it's the first version" do
          assert_difference("PostArchive.count", 1) do
            post = FactoryBot.create(:post)
          end
        end

        should "create a new version if it's been over an hour since the last update" do
          post = FactoryBot.create(:post)
          travel(6.hours) do
            assert_difference("PostArchive.count", 1) do
              post.update(tag_string: "zzz")
            end
          end
        end

        should "merge with the previous version if the updater is the same user and it's been less than an hour" do
          post = FactoryBot.create(:post)
          assert_difference("PostArchive.count", 0) do
            post.update(tag_string: "zzz")
          end
          assert_equal("zzz", post.versions.last.tags)
        end

        should "increment the updater's post_update_count" do
          PostArchive.sqs_service.stubs(:merge?).returns(false)
          post = FactoryBot.create(:post, :tag_string => "aaa bbb ccc")

          # XXX in the test environment the update count gets bumped twice: and
          # once by Post#post_update_count, and once by the counter cache. in
          # production the counter cache doesn't bump the count, because
          # versions are created on a separate server.
          assert_difference("CurrentUser.user.reload.post_update_count", 2) do
            post.update(tag_string: "zzz")
          end
        end

        should "reset its tag array cache" do
          post = FactoryBot.create(:post, :tag_string => "aaa bbb ccc")
          user = FactoryBot.create(:user)
          assert_equal(%w(aaa bbb ccc), post.tag_array)
          post.tag_string = "ddd eee fff"
          post.tag_string = "ddd eee fff"
          post.save
          assert_equal("ddd eee fff", post.tag_string)
          assert_equal(%w(ddd eee fff), post.tag_array)
        end

        should "create the actual tag records" do
          assert_difference("Tag.count", 3) do
            post = FactoryBot.create(:post, :tag_string => "aaa bbb ccc")
          end
        end

        should "update the post counts of relevant tag records" do
          post1 = FactoryBot.create(:post, :tag_string => "aaa bbb ccc")
          post2 = FactoryBot.create(:post, :tag_string => "bbb ccc ddd")
          post3 = FactoryBot.create(:post, :tag_string => "ccc ddd eee")
          assert_equal(1, Tag.find_by_name("aaa").post_count)
          assert_equal(2, Tag.find_by_name("bbb").post_count)
          assert_equal(3, Tag.find_by_name("ccc").post_count)
          post3.reload
          post3.tag_string = "xxx"
          post3.save
          assert_equal(1, Tag.find_by_name("aaa").post_count)
          assert_equal(2, Tag.find_by_name("bbb").post_count)
          assert_equal(2, Tag.find_by_name("ccc").post_count)
          assert_equal(1, Tag.find_by_name("ddd").post_count)
          assert_equal(0, Tag.find_by_name("eee").post_count)
          assert_equal(1, Tag.find_by_name("xxx").post_count)
        end

        should "update its tag counts" do
          artist_tag = FactoryBot.create(:artist_tag)
          copyright_tag = FactoryBot.create(:copyright_tag)
          general_tag = FactoryBot.create(:tag)
          new_post = FactoryBot.create(:post, :tag_string => "#{artist_tag.name} #{copyright_tag.name} #{general_tag.name}")
          assert_equal(1, new_post.tag_count_artist)
          assert_equal(1, new_post.tag_count_copyright)
          assert_equal(1, new_post.tag_count_general)
          assert_equal(0, new_post.tag_count_character)
          assert_equal(3, new_post.tag_count)

          new_post.tag_string = "babs"
          new_post.save
          assert_equal(0, new_post.tag_count_artist)
          assert_equal(0, new_post.tag_count_copyright)
          assert_equal(1, new_post.tag_count_general)
          assert_equal(0, new_post.tag_count_character)
          assert_equal(1, new_post.tag_count)
        end

        should "merge any tag changes that were made after loading the initial set of tags part 1" do
          post = FactoryBot.create(:post, :tag_string => "aaa bbb ccc")

          # user a adds <ddd>
          post_edited_by_user_a = Post.find(post.id)
          post_edited_by_user_a.old_tag_string = "aaa bbb ccc"
          post_edited_by_user_a.tag_string = "aaa bbb ccc ddd"
          post_edited_by_user_a.save

          # user b removes <ccc> adds <eee>
          post_edited_by_user_b = Post.find(post.id)
          post_edited_by_user_b.old_tag_string = "aaa bbb ccc"
          post_edited_by_user_b.tag_string = "aaa bbb eee"
          post_edited_by_user_b.save

          # final should be <aaa>, <bbb>, <ddd>, <eee>
          final_post = Post.find(post.id)
          assert_equal(%w(aaa bbb ddd eee), Tag.scan_tags(final_post.tag_string).sort)
        end

        should "merge any tag changes that were made after loading the initial set of tags part 2" do
          # This is the same as part 1, only the order of operations is reversed.
          # The results should be the same.

          post = FactoryBot.create(:post, :tag_string => "aaa bbb ccc")

          # user a removes <ccc> adds <eee>
          post_edited_by_user_a = Post.find(post.id)
          post_edited_by_user_a.old_tag_string = "aaa bbb ccc"
          post_edited_by_user_a.tag_string = "aaa bbb eee"
          post_edited_by_user_a.save

          # user b adds <ddd>
          post_edited_by_user_b = Post.find(post.id)
          post_edited_by_user_b.old_tag_string = "aaa bbb ccc"
          post_edited_by_user_b.tag_string = "aaa bbb ccc ddd"
          post_edited_by_user_b.save

          # final should be <aaa>, <bbb>, <ddd>, <eee>
          final_post = Post.find(post.id)
          assert_equal(%w(aaa bbb ddd eee), Tag.scan_tags(final_post.tag_string).sort)
        end

        should "merge any parent, source, and rating changes that were made after loading the initial set" do
          post = FactoryBot.create(:post, :parent => nil, :source => "", :rating => "q")
          parent_post = FactoryBot.create(:post)

          # user a changes rating to safe, adds parent
          post_edited_by_user_a = Post.find(post.id)
          post_edited_by_user_a.old_parent_id = ""
          post_edited_by_user_a.old_source = ""
          post_edited_by_user_a.old_rating = "q"
          post_edited_by_user_a.parent_id = parent_post.id
          post_edited_by_user_a.source = nil
          post_edited_by_user_a.rating = "s"
          post_edited_by_user_a.save

          # user b adds source
          post_edited_by_user_b = Post.find(post.id)
          post_edited_by_user_b.old_parent_id = ""
          post_edited_by_user_b.old_source = ""
          post_edited_by_user_b.old_rating = "q"
          post_edited_by_user_b.parent_id = nil
          post_edited_by_user_b.source = "http://example.com"
          post_edited_by_user_b.rating = "q"
          post_edited_by_user_b.save

          # final post should be rated safe and have the set parent and source
          final_post = Post.find(post.id)
          assert_equal(parent_post.id, final_post.parent_id)
          assert_equal("http://example.com", final_post.source)
          assert_equal("s", final_post.rating)
        end
      end

      context "that has been tagged with a metatag" do
        should "not include the metatag in its tag string" do
          post = FactoryBot.create(:post)
          post.tag_string = "aaa pool:1234 pool:test rating:s fav:bob"
          post.save
          assert_equal("aaa", post.tag_string)
        end
      end

      context "with a source" do
        context "that is not from pixiv" do
          should "clear the pixiv id" do
            @post.pixiv_id = 1234
            @post.update(source: "http://fc06.deviantart.net/fs71/f/2013/295/d/7/you_are_already_dead__by_mar11co-d6rgm0e.jpg")
            assert_nil(@post.pixiv_id)

            @post.pixiv_id = 1234
            @post.update(source: "http://pictures.hentai-foundry.com//a/AnimeFlux/219123.jpg")
            assert_nil(@post.pixiv_id)
          end
        end

        context "that is from pixiv" do
          should "save the pixiv id" do
            @post.update(source: "http://i1.pixiv.net/img-original/img/2014/10/02/13/51/23/46304396_p0.png")
            assert_equal(46304396, @post.pixiv_id)
            @post.pixiv_id = nil
          end
        end

        should "normalize pixiv links" do
          @post.source = "http://i2.pixiv.net/img12/img/zenze/39749565.png"
          assert_equal("https://www.pixiv.net/member_illust.php?mode=medium&illust_id=39749565", @post.normalized_source)

          @post.source = "http://i1.pixiv.net/img53/img/themare/39735353_big_p1.jpg"
          assert_equal("https://www.pixiv.net/member_illust.php?mode=medium&illust_id=39735353", @post.normalized_source)

          @post.source = "http://i1.pixiv.net/c/150x150/img-master/img/2010/11/30/08/39/58/14901720_p0_master1200.jpg"
          assert_equal("https://www.pixiv.net/member_illust.php?mode=medium&illust_id=14901720", @post.normalized_source)

          @post.source = "http://i1.pixiv.net/img-original/img/2010/11/30/08/39/58/14901720_p0.png"
          assert_equal("https://www.pixiv.net/member_illust.php?mode=medium&illust_id=14901720", @post.normalized_source)

          @post.source = "http://i2.pixiv.net/img-zip-ugoira/img/2014/08/05/06/01/10/44524589_ugoira1920x1080.zip"
          assert_equal("https://www.pixiv.net/member_illust.php?mode=medium&illust_id=44524589", @post.normalized_source)
        end

        should "normalize nicoseiga links" do
          @post.source = "http://lohas.nicoseiga.jp/priv/3521156?e=1382558156&h=f2e089256abd1d453a455ec8f317a6c703e2cedf"
          assert_equal("https://seiga.nicovideo.jp/seiga/im3521156", @post.normalized_source)
          @post.source = "http://lohas.nicoseiga.jp/priv/b80f86c0d8591b217e7513a9e175e94e00f3c7a1/1384936074/3583893"
          assert_equal("https://seiga.nicovideo.jp/seiga/im3583893", @post.normalized_source)
        end

        should "normalize twitpic links" do
          @post.source = "http://d3j5vwomefv46c.cloudfront.net/photos/large/820960031.jpg?1384107199"
          assert_equal("https://twitpic.com/dks0tb", @post.normalized_source)
        end

        should "normalize deviantart links" do
          @post.source = "http://fc06.deviantart.net/fs71/f/2013/295/d/7/you_are_already_dead__by_mar11co-d6rgm0e.jpg"
          assert_equal("https://www.deviantart.com/mar11co/art/You-Are-Already-Dead-408921710", @post.normalized_source)
          @post.source = "http://fc00.deviantart.net/fs71/f/2013/337/3/5/35081351f62b432f84eaeddeb4693caf-d6wlrqs.jpg"
          assert_equal("https://deviantart.com/deviation/417560500", @post.normalized_source)
        end

        should "normalize karabako links" do
          @post.source = "http://www.karabako.net/images/karabako_38835.jpg"
          assert_equal("http://www.karabako.net/post/view/38835", @post.normalized_source)
        end

        should "normalize twipple links" do
          @post.source = "http://p.twpl.jp/show/orig/mI2c3"
          assert_equal("http://p.twipple.jp/mI2c3", @post.normalized_source)
        end

        should "normalize hentai foundry links" do
          @post.source = "http://pictures.hentai-foundry.com//a/AnimeFlux/219123.jpg"
          assert_equal("https://www.hentai-foundry.com/pictures/user/AnimeFlux/219123", @post.normalized_source)

          @post.source = "http://pictures.hentai-foundry.com/a/AnimeFlux/219123/Mobile-Suit-Equestria-rainbow-run.jpg"
          assert_equal("https://www.hentai-foundry.com/pictures/user/AnimeFlux/219123", @post.normalized_source)
        end
      end

      context "when validating tags" do
        should "warn when creating a new general tag" do
          @post.add_tag("tag")
          @post.save

          assert_match(/Created 1 new tag: \[\[tag\]\]/, @post.warnings.full_messages.join)
        end

        should "warn when adding an artist tag without an artist entry" do
          @post.add_tag("artist:bkub")
          @post.save

          assert_match(/Artist \[\[bkub\]\] requires an artist entry./, @post.warnings.full_messages.join)
        end

        should "warn when a tag removal failed due to implications or automatic tags" do
          ti = FactoryBot.create(:tag_implication, antecedent_name: "cat", consequent_name: "animal")
          @post.reload
          @post.update(old_tag_string: @post.tag_string, tag_string: "chen_(cosplay) char:chen cosplay cat animal")
          @post.warnings.clear
          @post.reload
          @post.update(old_tag_string: @post.tag_string, tag_string: "chen_(cosplay) chen cosplay cat -cosplay")

          assert_match(/\[\[animal\]\] and \[\[cosplay\]\] could not be removed./, @post.warnings.full_messages.join)
        end

        should "warn when a post from a known source is missing an artist tag" do
          post = FactoryBot.build(:post, source: "https://www.pixiv.net/member_illust.php?mode=medium&illust_id=65985331")
          post.save
          assert_match(/Artist tag is required/, post.warnings.full_messages.join)
        end

        should "warn when missing a copyright tag" do
          assert_match(/Copyright tag is required/, @post.warnings.full_messages.join)
        end

        should "warn when an upload doesn't have enough tags" do
          post = FactoryBot.create(:post, tag_string: "tagme")
          assert_match(/Uploads must have at least \d+ general tags/, post.warnings.full_messages.join)
        end
      end
    end
  end

  context "Updating:" do
    context "an existing post" do
      setup { @post = FactoryBot.create(:post) }

      should "call Tag.increment_post_counts with the correct params" do
        @post.reload
        Tag.expects(:increment_post_counts).once.with(["abc"])
        @post.update(tag_string: "tag1 abc")
      end
    end

    context "A rating unlocked post" do
      setup { @post = FactoryBot.create(:post) }
      subject { @post }

      should "not allow values S, safe, derp" do
        ["S", "safe", "derp"].each do |rating|
          subject.rating = rating
          assert(!subject.valid?)
        end
      end

      should "allow values s, q, e" do
        ["s", "q", "e"].each do |rating|
          subject.rating = rating
          assert(subject.valid?)
        end
      end
    end

    context "A rating locked post" do
      setup { @post = FactoryBot.create(:post, :is_rating_locked => true) }
      subject { @post }

      should "not allow values S, safe, derp" do
        ["S", "safe", "derp"].each do |rating|
          subject.rating = rating
          assert(!subject.valid?)
        end
      end

      should "not allow values s, e" do
        ["s", "e"].each do |rating|
          subject.rating = rating
          assert(!subject.valid?)
        end
      end
    end
  end

  context "Favorites:" do
    context "Removing a post from a user's favorites" do
      setup do
        @user = FactoryBot.create(:contributor_user)
        @post = FactoryBot.create(:post)
        @post.add_favorite!(@user)
        @user.reload
      end

      should "decrement the user's favorite_count" do
        assert_difference("@user.favorite_count", -1) do
          @post.remove_favorite!(@user)
        end
      end

      should "decrement the post's score for gold users" do
        assert_difference("@post.score", -1) do
          @post.remove_favorite!(@user)
        end
      end

      should "not decrement the post's score for basic users" do
        @member = FactoryBot.create(:user)

        assert_no_difference("@post.score") { @post.add_favorite!(@member) }
        assert_no_difference("@post.score") { @post.remove_favorite!(@member) }
      end

      should "not decrement the user's favorite_count if the user did not favorite the post" do
        @post2 = FactoryBot.create(:post)
        assert_no_difference("@user.favorite_count") do
          @post2.remove_favorite!(@user)
        end
      end
    end

    context "Adding a post to a user's favorites" do
      setup do
        @user = FactoryBot.create(:contributor_user)
        @post = FactoryBot.create(:post)
      end

      should "periodically clean the fav_string" do
        @post.update_column(:fav_string, "fav:1 fav:1 fav:1")
        @post.update_column(:fav_count, 3)
        @post.stubs(:clean_fav_string?).returns(true)
        @post.append_user_to_fav_string(2)
        assert_equal("fav:1 fav:2", @post.fav_string)
        assert_equal(2, @post.fav_count)
      end

      should "increment the user's favorite_count" do
        assert_difference("@user.favorite_count", 1) do
          @post.add_favorite!(@user)
        end
      end

      should "increment the post's score for gold users" do
        @post.add_favorite!(@user)
        assert_equal(1, @post.score)
      end

      should "not increment the post's score for basic users" do
        @member = FactoryBot.create(:user)
        @post.add_favorite!(@member)
        assert_equal(0, @post.score)
      end

      should "update the fav strings on the post" do
        @post.add_favorite!(@user)
        @post.reload
        assert_equal("fav:#{@user.id}", @post.fav_string)
        assert(Favorite.exists?(:user_id => @user.id, :post_id => @post.id))

        assert_raises(Favorite::Error) { @post.add_favorite!(@user) }
        @post.reload
        assert_equal("fav:#{@user.id}", @post.fav_string)
        assert(Favorite.exists?(:user_id => @user.id, :post_id => @post.id))

        @post.remove_favorite!(@user)
        @post.reload
        assert_equal("", @post.fav_string)
        assert(!Favorite.exists?(:user_id => @user.id, :post_id => @post.id))

        @post.remove_favorite!(@user)
        @post.reload
        assert_equal("", @post.fav_string)
        assert(!Favorite.exists?(:user_id => @user.id, :post_id => @post.id))
      end
    end

    context "Moving favorites to a parent post" do
      setup do
        @parent = FactoryBot.create(:post)
        @child = FactoryBot.create(:post, parent: @parent)

        @user1 = FactoryBot.create(:user, enable_privacy_mode: true)
        @gold1 = FactoryBot.create(:gold_user)
        @supervoter1 = FactoryBot.create(:user, is_super_voter: true)

        @child.add_favorite!(@user1)
        @child.add_favorite!(@gold1)
        @child.add_favorite!(@supervoter1)
        @parent.add_favorite!(@supervoter1)

        @child.give_favorites_to_parent
        @child.reload
        @parent.reload
      end

      should "move the favorites" do
        assert_equal(0, @child.fav_count)
        assert_equal(0, @child.favorites.count)
        assert_equal("", @child.fav_string)
        assert_equal([], @child.favorites.pluck(:user_id))

        assert_equal(3, @parent.fav_count)
        assert_equal(3, @parent.favorites.count)
      end

      should "create a vote for each user who can vote" do
        assert(@parent.votes.where(user: @gold1).exists?)
        assert(@parent.votes.where(user: @supervoter1).exists?)
        assert_equal(4, @parent.score)
      end
    end
  end

  context "Pools:" do
    setup do
      SqsService.any_instance.stubs(:send_message)
    end

    context "Removing a post from a pool" do
      should "update the post's pool string" do
        post = FactoryBot.create(:post)
        pool = FactoryBot.create(:pool)
        post.add_pool!(pool)
        post.remove_pool!(pool)
        post.reload
        assert_equal("", post.pool_string)
        post.remove_pool!(pool)
        post.reload
        assert_equal("", post.pool_string)
      end
    end

    context "Adding a post to a pool" do
      should "update the post's pool string" do
        post = FactoryBot.create(:post)
        pool = FactoryBot.create(:pool)
        post.add_pool!(pool)
        post.reload
        assert_equal("pool:#{pool.id} pool:series", post.pool_string)
        post.add_pool!(pool)
        post.reload
        assert_equal("pool:#{pool.id} pool:series", post.pool_string)
        post.remove_pool!(pool)
        post.reload
        assert_equal("", post.pool_string)
      end
    end
  end

  context "Uploading:" do
    context "Uploading a post" do
      should "capture who uploaded the post" do
        post = FactoryBot.create(:post)
        user1 = FactoryBot.create(:user)
        user2 = FactoryBot.create(:user)
        user3 = FactoryBot.create(:user)

        post.uploader = user1
        assert_equal(user1.id, post.uploader_id)

        post.uploader_id = user2.id
        assert_equal(user2.id, post.uploader_id)
        assert_equal(user2.id, post.uploader_id)
        assert_equal(user2.name, post.uploader.name)
      end

      context "tag post counts" do
        setup { @post = FactoryBot.build(:post) }

        should "call Tag.increment_post_counts with the correct params" do
          Tag.expects(:increment_post_counts).once.with(["tag1", "tag2"])
          @post.save
        end
      end

      should "increment the uploaders post_upload_count" do
        assert_difference(-> { CurrentUser.user.post_upload_count }) do
          post = FactoryBot.create(:post, uploader: CurrentUser.user)
          CurrentUser.user.reload
        end
      end
    end
  end

  context "Searching:" do
    setup do
      mock_pool_archive_service!
    end
    
    should "return posts for the age:<1minute tag" do
      post = FactoryBot.create(:post)
      assert_tag_match([post], "age:<1minute")
    end

    should "return posts for the age:<1minute tag when the user is in Pacific time zone" do
      post = FactoryBot.create(:post)
      Time.zone = "Pacific Time (US & Canada)"
      assert_tag_match([post], "age:<1minute")
      Time.zone = "Eastern Time (US & Canada)"
    end

    should "return posts for the age:<1minute tag when the user is in Tokyo time zone" do
      post = FactoryBot.create(:post)
      Time.zone = "Asia/Tokyo"
      assert_tag_match([post], "age:<1minute")
      Time.zone = "Eastern Time (US & Canada)"
    end

    should "return posts for the ' tag" do
      post1 = FactoryBot.create(:post, :tag_string => "'")
      post2 = FactoryBot.create(:post, :tag_string => "aaa bbb")

      assert_tag_match([post1], "'")
    end

    should "return posts for the \\ tag" do
      post1 = FactoryBot.create(:post, :tag_string => "\\")
      post2 = FactoryBot.create(:post, :tag_string => "aaa bbb")

      assert_tag_match([post1], "\\")
    end

    should "return posts for the ( tag" do
      post1 = FactoryBot.create(:post, :tag_string => "(")
      post2 = FactoryBot.create(:post, :tag_string => "aaa bbb")

      assert_tag_match([post1], "(")
    end

    should "return posts for the ? tag" do
      post1 = FactoryBot.create(:post, :tag_string => "?")
      post2 = FactoryBot.create(:post, :tag_string => "aaa bbb")

      assert_tag_match([post1], "?")
    end

    should "return posts for 1 tag" do
      post1 = FactoryBot.create(:post, :tag_string => "aaa")
      post2 = FactoryBot.create(:post, :tag_string => "aaa bbb")
      post3 = FactoryBot.create(:post, :tag_string => "bbb ccc")

      assert_tag_match([post2, post1], "aaa")
    end

    should "return posts for a 2 tag join" do
      post1 = FactoryBot.create(:post, :tag_string => "aaa")
      post2 = FactoryBot.create(:post, :tag_string => "aaa bbb")
      post3 = FactoryBot.create(:post, :tag_string => "bbb ccc")

      assert_tag_match([post2], "aaa bbb")
    end

    should "return posts for a 2 tag union" do
      post1 = FactoryBot.create(:post, :tag_string => "aaa")
      post2 = FactoryBot.create(:post, :tag_string => "aaab bbb")
      post3 = FactoryBot.create(:post, :tag_string => "bbb ccc")

      assert_tag_match([post3, post1], "~aaa ~ccc")
    end

    should "return posts for 1 tag with exclusion" do
      post1 = FactoryBot.create(:post, :tag_string => "aaa")
      post2 = FactoryBot.create(:post, :tag_string => "aaa bbb")
      post3 = FactoryBot.create(:post, :tag_string => "bbb ccc")

      assert_tag_match([post1], "aaa -bbb")
    end

    should "return posts for 1 tag with a pattern" do
      post1 = FactoryBot.create(:post, :tag_string => "aaa")
      post2 = FactoryBot.create(:post, :tag_string => "aaab bbb")
      post3 = FactoryBot.create(:post, :tag_string => "bbb ccc")

      assert_tag_match([post2, post1], "a*")
    end

    should "return posts for 2 tags, one with a pattern" do
      post1 = FactoryBot.create(:post, :tag_string => "aaa")
      post2 = FactoryBot.create(:post, :tag_string => "aaab bbb")
      post3 = FactoryBot.create(:post, :tag_string => "bbb ccc")

      assert_tag_match([post2], "a* bbb")
    end

    should "return posts for the id:<N> metatag" do
      posts = FactoryBot.create_list(:post, 3)

      assert_tag_match([posts[1]], "id:#{posts[1].id}")
      assert_tag_match([posts[2]], "id:>#{posts[1].id}")
      assert_tag_match([posts[0]], "id:<#{posts[1].id}")

      assert_tag_match([posts[2], posts[0]], "-id:#{posts[1].id}")
      assert_tag_match([posts[2], posts[1]], "id:>=#{posts[1].id}")
      assert_tag_match([posts[1], posts[0]], "id:<=#{posts[1].id}")
      assert_tag_match([posts[2], posts[0]], "id:#{posts[0].id},#{posts[2].id}")
      assert_tag_match(posts.reverse, "id:#{posts[0].id}..#{posts[2].id}")
    end

    should "return posts for the fav:<name> metatag" do
      users = FactoryBot.create_list(:user, 2)
      posts = users.map do |u|
        CurrentUser.scoped(u) { FactoryBot.create(:post, tag_string: "fav:#{u.name}") }
      end

      assert_tag_match([posts[0]], "fav:#{users[0].name}")
      assert_tag_match([posts[1]], "-fav:#{users[0].name}")
    end

    should "return posts for the ordfav:<name> metatag" do
      post1 = FactoryBot.create(:post, tag_string: "fav:#{CurrentUser.name}")
      post2 = FactoryBot.create(:post, tag_string: "fav:#{CurrentUser.name}")

      assert_tag_match([post2, post1], "ordfav:#{CurrentUser.name}")
    end

    should "return posts for the pool:<name> metatag" do
      SqsService.any_instance.stubs(:send_message)

      FactoryBot.create(:pool, name: "test_a", category: "series")
      FactoryBot.create(:pool, name: "test_b", category: "collection")
      post1 = FactoryBot.create(:post, tag_string: "pool:test_a")
      post2 = FactoryBot.create(:post, tag_string: "pool:test_b")

      assert_tag_match([post1], "pool:test_a")
      assert_tag_match([post2], "-pool:test_a")
      assert_tag_match([], "-pool:test_a -pool:test_b")
      assert_tag_match([post2, post1], "pool:test*")

      assert_tag_match([post2, post1], "pool:any")
      assert_tag_match([], "pool:none")

      assert_tag_match([post1], "pool:series")
      assert_tag_match([post2], "-pool:series")
      assert_tag_match([post2], "pool:collection")
      assert_tag_match([post1], "-pool:collection")
    end

    should "return posts for the ordpool:<name> metatag" do
      posts = FactoryBot.create_list(:post, 2, tag_string: "newpool:test")

      assert_tag_match(posts, "ordpool:test")
    end

    should "return posts for the ordpool:<name> metatag for a series pool containing duplicate posts" do
      posts = FactoryBot.create_list(:post, 2)
      pool = FactoryBot.create(:pool, name: "test", category: "series", post_ids: [posts[0].id, posts[1].id, posts[1].id])

      assert_tag_match([posts[0], posts[1], posts[1]], "ordpool:test")
    end

    should "return posts for the parent:<N> metatag" do
      parent = FactoryBot.create(:post)
      child = FactoryBot.create(:post, tag_string: "parent:#{parent.id}")

      assert_tag_match([parent], "parent:none")
      assert_tag_match([child], "-parent:none")
      assert_tag_match([child, parent], "parent:#{parent.id}")
      assert_tag_match([child], "parent:#{child.id}")

      assert_tag_match([child], "child:none")
      assert_tag_match([parent], "child:any")
    end

    should "return posts for the favgroup:<name> metatag" do
      favgroups = FactoryBot.create_list(:favorite_group, 2, creator: CurrentUser.user)
      posts = favgroups.map { |g| FactoryBot.create(:post, tag_string: "favgroup:#{g.name}") }

      assert_tag_match([posts[0]], "favgroup:#{favgroups[0].name}")
      assert_tag_match([posts[1]], "-favgroup:#{favgroups[0].name}")
      assert_tag_match([], "-favgroup:#{favgroups[0].name} -favgroup:#{favgroups[1].name}")
    end

    should "return posts for the user:<name> metatag" do
      users = FactoryBot.create_list(:user, 2)
      posts = users.map { |u| FactoryBot.create(:post, uploader: u) }

      assert_tag_match([posts[0]], "user:#{users[0].name}")
      assert_tag_match([posts[1]], "-user:#{users[0].name}")
    end

    should "return posts for the approver:<name> metatag" do
      users = FactoryBot.create_list(:user, 2)
      posts = users.map { |u| FactoryBot.create(:post, approver: u) }
      posts << FactoryBot.create(:post, approver: nil)

      assert_tag_match([posts[0]], "approver:#{users[0].name}")
      assert_tag_match([posts[1]], "-approver:#{users[0].name}")
      assert_tag_match([posts[1], posts[0]], "approver:any")
      assert_tag_match([posts[2]], "approver:none")
    end

    should "return posts for the commenter:<name> metatag" do
      users = FactoryBot.create_list(:user, 2, created_at: 2.weeks.ago)
      posts = FactoryBot.create_list(:post, 2)
      comms = users.zip(posts).map { |u, p| as(u) { FactoryBot.create(:comment, post: p) } }

      assert_tag_match([posts[0]], "commenter:#{users[0].name}")
      assert_tag_match([posts[1]], "commenter:#{users[1].name}")
    end

    should "return posts for the commenter:<any|none> metatag" do
      posts = FactoryBot.create_list(:post, 2)
      FactoryBot.create(:comment, post: posts[0], is_deleted: false)
      FactoryBot.create(:comment, post: posts[1], is_deleted: true)

      assert_tag_match([posts[0]], "commenter:any")
      assert_tag_match([posts[1]], "commenter:none")
    end

    should "return posts for the noter:<name> metatag" do
      users = FactoryBot.create_list(:user, 2)
      posts = FactoryBot.create_list(:post, 2)
      notes = users.zip(posts).map { |u, p| FactoryBot.create(:note, creator: u, post: p) }

      assert_tag_match([posts[0]], "noter:#{users[0].name}")
      assert_tag_match([posts[1]], "noter:#{users[1].name}")
    end

    should "return posts for the noter:<any|none> metatag" do
      posts = FactoryBot.create_list(:post, 2)
      FactoryBot.create(:note, post: posts[0], is_active: true)
      FactoryBot.create(:note, post: posts[1], is_active: false)

      assert_tag_match([posts[0]], "noter:any")
      assert_tag_match([posts[1]], "noter:none")
    end

    should "return posts for the note_count:<N> metatag" do
      posts = FactoryBot.create_list(:post, 3)
      FactoryBot.create(:note, post: posts[0], is_active: true)
      FactoryBot.create(:note, post: posts[1], is_active: false)

      assert_tag_match([posts[1], posts[0]], "note_count:1")
      assert_tag_match([posts[0]], "active_note_count:1")
      assert_tag_match([posts[1]], "deleted_note_count:1")

      assert_tag_match([posts[1], posts[0]], "notes:1")
      assert_tag_match([posts[0]], "active_notes:1")
      assert_tag_match([posts[1]], "deleted_notes:1")
    end

    should "return posts for the artcomm:<name> metatag" do
      users = FactoryBot.create_list(:user, 2)
      posts = FactoryBot.create_list(:post, 2)
      users.zip(posts).map do |u, p|
        CurrentUser.scoped(u) { FactoryBot.create(:artist_commentary, post: p) }
      end

      assert_tag_match([posts[0]], "artcomm:#{users[0].name}")
      assert_tag_match([posts[1]], "artcomm:#{users[1].name}")
    end

    should "return posts for the date:<d> metatag" do
      post = FactoryBot.create(:post, created_at: Time.parse("2017-01-01 12:00"))

      assert_tag_match([post], "date:2017-01-01")
    end

    should "return posts for the age:<n> metatag" do
      post = FactoryBot.create(:post)

      assert_tag_match([post], "age:<60")
      assert_tag_match([post], "age:<60s")
      assert_tag_match([post], "age:<1mi")
      assert_tag_match([post], "age:<1h")
      assert_tag_match([post], "age:<1d")
      assert_tag_match([post], "age:<1w")
      assert_tag_match([post], "age:<1mo")
      assert_tag_match([post], "age:<1y")
    end

    should "return posts for the ratio:<x:y> metatag" do
      post = FactoryBot.create(:post, image_width: 1000, image_height: 500)

      assert_tag_match([post], "ratio:2:1")
      assert_tag_match([post], "ratio:2.0")
    end

    should "return posts for the status:<type> metatag" do
      pending = FactoryBot.create(:post, is_pending: true)
      flagged = FactoryBot.create(:post, is_flagged: true)
      deleted = FactoryBot.create(:post, is_deleted: true)
      banned  = FactoryBot.create(:post, is_banned: true)
      all = [banned, deleted, flagged, pending]

      assert_tag_match([flagged, pending], "status:modqueue")
      assert_tag_match([pending], "status:pending")
      assert_tag_match([flagged], "status:flagged")
      assert_tag_match([deleted], "status:deleted")
      assert_tag_match([banned],  "status:banned")
      assert_tag_match([], "status:active")
      assert_tag_match(all, "status:any")
      assert_tag_match(all, "status:all")

      assert_tag_match(all - [flagged, pending], "-status:modqueue")
      assert_tag_match(all - [pending], "-status:pending")
      assert_tag_match(all - [flagged], "-status:flagged")
      assert_tag_match(all - [deleted], "-status:deleted")
      assert_tag_match(all - [banned],  "-status:banned")
      assert_tag_match(all, "-status:active")
    end

    should "return posts for the status:unmoderated metatag" do
      flagged = FactoryBot.create(:post, is_flagged: true)
      pending = FactoryBot.create(:post, is_pending: true)
      disapproved = FactoryBot.create(:post, is_pending: true)

      FactoryBot.create(:post_flag, post: flagged)
      FactoryBot.create(:post_disapproval, post: disapproved, reason: "disinterest")

      assert_tag_match([pending, flagged], "status:unmoderated")
    end

    should "respect the 'Deleted post filter' option when using the status:banned metatag" do
      deleted = FactoryBot.create(:post, is_deleted: true, is_banned: true)
      undeleted = FactoryBot.create(:post, is_banned: true)

      CurrentUser.hide_deleted_posts = true
      assert_tag_match([undeleted], "status:banned")

      CurrentUser.hide_deleted_posts = false
      assert_tag_match([undeleted, deleted], "status:banned")
    end

    should "return posts for the filetype:<ext> metatag" do
      png = FactoryBot.create(:post, file_ext: "png")
      jpg = FactoryBot.create(:post, file_ext: "jpg")

      assert_tag_match([png], "filetype:png")
      assert_tag_match([jpg], "-filetype:png")
    end

    should "return posts for the tagcount:<n> metatags" do
      post = FactoryBot.create(:post, tag_string: "artist:wokada copyright:vocaloid char:hatsune_miku twintails")

      assert_tag_match([post], "tagcount:4")
      assert_tag_match([post], "arttags:1")
      assert_tag_match([post], "copytags:1")
      assert_tag_match([post], "chartags:1")
      assert_tag_match([post], "gentags:1")
    end

    should "return posts for the md5:<md5> metatag" do
      post1 = FactoryBot.create(:post, :md5 => "abcd")
      post2 = FactoryBot.create(:post)

      assert_tag_match([post1], "md5:abcd")
    end

    should "return posts for a source search" do
      post1 = FactoryBot.create(:post, :source => "abcd")
      post2 = FactoryBot.create(:post, :source => "abcdefg")
      post3 = FactoryBot.create(:post, :source => "")

      assert_tag_match([post2], "source:abcde")
      assert_tag_match([post3, post1], "-source:abcde")

      assert_tag_match([post3], "source:none")
      assert_tag_match([post2, post1], "-source:none")
    end

    should "return posts for a case insensitive source search" do
      post1 = FactoryBot.create(:post, :source => "ABCD")
      post2 = FactoryBot.create(:post, :source => "1234")

      assert_tag_match([post1], "source:abcd")
    end

    should "return posts for a pixiv source search" do
      url = "http://i1.pixiv.net/img123/img/artist-name/789.png"
      post = FactoryBot.create(:post, :source => url)

      assert_tag_match([post], "source:*.pixiv.net/img*/artist-name/*")
      assert_tag_match([],     "source:*.pixiv.net/img*/artist-fake/*")
      assert_tag_match([post], "source:http://*.pixiv.net/img*/img/artist-name/*")
      assert_tag_match([],     "source:http://*.pixiv.net/img*/img/artist-fake/*")
    end

    should "return posts for a pixiv id search (type 1)" do
      url = "http://i1.pixiv.net/img-inf/img/2013/03/14/03/02/36/34228050_s.jpg"
      post = FactoryBot.create(:post, :source => url)
      assert_tag_match([post], "pixiv_id:34228050")
    end

    should "return posts for a pixiv id search (type 2)" do
      url = "http://i1.pixiv.net/img123/img/artist-name/789.png"
      post = FactoryBot.create(:post, :source => url)
      assert_tag_match([post], "pixiv_id:789")
    end

    should "return posts for a pixiv id search (type 3)" do
      url = "http://www.pixiv.net/member_illust.php?mode=manga_big&illust_id=19113635&page=0"
      post = FactoryBot.create(:post, :source => url)
      assert_tag_match([post], "pixiv_id:19113635")
    end

    should "return posts for a pixiv id search (type 4)" do
      url = "http://i2.pixiv.net/img70/img/disappearedstump/34551381_p3.jpg?1364424318"
      post = FactoryBot.create(:post, :source => url)
      assert_tag_match([post], "pixiv_id:34551381")
    end

    should "return posts for a pixiv_id:any search" do
      url = "http://i1.pixiv.net/img-original/img/2014/10/02/13/51/23/46304396_p0.png"
      post = FactoryBot.create(:post, source: url)
      assert_tag_match([post], "pixiv_id:any")
    end

    should "return posts for a pixiv_id:none search" do
      post = FactoryBot.create(:post)
      assert_tag_match([post], "pixiv_id:none")
    end

    context "saved searches" do
      setup do
        SavedSearch.stubs(:enabled?).returns(true)
        @post1 = FactoryBot.create(:post, tag_string: "aaa")
        @post2 = FactoryBot.create(:post, tag_string: "bbb")
        FactoryBot.create(:saved_search, query: "aaa", labels: ["zzz"], user: CurrentUser.user)
        FactoryBot.create(:saved_search, query: "bbb", user: CurrentUser.user)
      end

      context "labeled" do
        should "work" do
          SavedSearch.expects(:post_ids_for).with(CurrentUser.id, label: "zzz").returns([@post1.id])
          assert_tag_match([@post1], "search:zzz")          
        end
      end

      context "missing" do
        should "work" do
          SavedSearch.expects(:post_ids_for).with(CurrentUser.id, label: "uncategorized").returns([@post2.id])
          assert_tag_match([@post2], "search:uncategorized")
        end
      end

      context "all" do
        should "work" do
          SavedSearch.expects(:post_ids_for).with(CurrentUser.id).returns([@post1.id, @post2.id])
          assert_tag_match([@post2, @post1], "search:all")          
        end
      end
    end

    should "return posts for a rating:<s|q|e> metatag" do
      s = FactoryBot.create(:post, :rating => "s")
      q = FactoryBot.create(:post, :rating => "q")
      e = FactoryBot.create(:post, :rating => "e")
      all = [e, q, s]

      assert_tag_match([s], "rating:s")
      assert_tag_match([q], "rating:q")
      assert_tag_match([e], "rating:e")

      assert_tag_match(all - [s], "-rating:s")
      assert_tag_match(all - [q], "-rating:q")
      assert_tag_match(all - [e], "-rating:e")
    end

    should "return posts for a locked:<rating|note|status> metatag" do
      rating_locked = FactoryBot.create(:post, is_rating_locked: true)
      note_locked   = FactoryBot.create(:post, is_note_locked: true)
      status_locked = FactoryBot.create(:post, is_status_locked: true)
      all = [status_locked, note_locked, rating_locked]

      assert_tag_match([rating_locked], "locked:rating")
      assert_tag_match([note_locked], "locked:note")
      assert_tag_match([status_locked], "locked:status")

      assert_tag_match(all - [rating_locked], "-locked:rating")
      assert_tag_match(all - [note_locked], "-locked:note")
      assert_tag_match(all - [status_locked], "-locked:status")
    end

    should "return posts for a upvote:<user>, downvote:<user> metatag" do
      CurrentUser.scoped(FactoryBot.create(:mod_user)) do
        upvoted   = FactoryBot.create(:post, tag_string: "upvote:self")
        downvoted = FactoryBot.create(:post, tag_string: "downvote:self")

        assert_tag_match([upvoted],   "upvote:#{CurrentUser.name}")
        assert_tag_match([downvoted], "downvote:#{CurrentUser.name}")
      end
    end

    should "return posts for a disapproval:<type> metatag" do
      CurrentUser.scoped(FactoryBot.create(:mod_user)) do
        pending     = FactoryBot.create(:post, is_pending: true)
        disapproved = FactoryBot.create(:post, is_pending: true)
        disapproval = FactoryBot.create(:post_disapproval, post: disapproved, reason: "disinterest")

        assert_tag_match([pending],     "disapproval:none")
        assert_tag_match([disapproved], "disapproval:any")
        assert_tag_match([disapproved], "disapproval:disinterest")
        assert_tag_match([],            "disapproval:breaks_rules")

        assert_tag_match([disapproved],          "-disapproval:none")
        assert_tag_match([pending],              "-disapproval:any")
        assert_tag_match([pending],              "-disapproval:disinterest")
        assert_tag_match([disapproved, pending], "-disapproval:breaks_rules")
      end
    end

    should "return posts ordered by a particular attribute" do
      posts = (1..2).map do |n|
        tags = ["tagme", "gentag1 gentag2 artist:arttag char:chartag copy:copytag"]

        p = FactoryBot.create(
          :post,
          score: n,
          fav_count: n,
          file_size: 1.megabyte * n,
          # posts[0] is portrait, posts[1] is landscape. posts[1].mpixels > posts[0].mpixels.
          image_height: 100*n*n,
          image_width: 100*(3-n)*n,
          tag_string: tags[n-1],
        )

        FactoryBot.create(:artist_commentary, post: p)
        FactoryBot.create(:comment, post: p, do_not_bump_post: false)
        FactoryBot.create(:note, post: p)
        p
      end

      FactoryBot.create(:note, post: posts.second)

      assert_tag_match(posts.reverse, "order:id_desc")
      assert_tag_match(posts.reverse, "order:score")
      assert_tag_match(posts.reverse, "order:favcount")
      assert_tag_match(posts.reverse, "order:change")
      assert_tag_match(posts.reverse, "order:comment")
      assert_tag_match(posts.reverse, "order:comment_bumped")
      assert_tag_match(posts.reverse, "order:note")
      assert_tag_match(posts.reverse, "order:artcomm")
      assert_tag_match(posts.reverse, "order:mpixels")
      assert_tag_match(posts.reverse, "order:portrait")
      assert_tag_match(posts.reverse, "order:filesize")
      assert_tag_match(posts.reverse, "order:tagcount")
      assert_tag_match(posts.reverse, "order:gentags")
      assert_tag_match(posts.reverse, "order:arttags")
      assert_tag_match(posts.reverse, "order:chartags")
      assert_tag_match(posts.reverse, "order:copytags")
      assert_tag_match(posts.reverse, "order:rank")
      assert_tag_match(posts.reverse, "order:note_count")
      assert_tag_match(posts.reverse, "order:note_count_desc")
      assert_tag_match(posts.reverse, "order:notes")
      assert_tag_match(posts.reverse, "order:notes_desc")

      assert_tag_match(posts, "order:id_asc")
      assert_tag_match(posts, "order:score_asc")
      assert_tag_match(posts, "order:favcount_asc")
      assert_tag_match(posts, "order:change_asc")
      assert_tag_match(posts, "order:comment_asc")
      assert_tag_match(posts, "order:comment_bumped_asc")
      assert_tag_match(posts, "order:artcomm_asc")
      assert_tag_match(posts, "order:note_asc")
      assert_tag_match(posts, "order:mpixels_asc")
      assert_tag_match(posts, "order:landscape")
      assert_tag_match(posts, "order:filesize_asc")
      assert_tag_match(posts, "order:tagcount_asc")
      assert_tag_match(posts, "order:gentags_asc")
      assert_tag_match(posts, "order:arttags_asc")
      assert_tag_match(posts, "order:chartags_asc")
      assert_tag_match(posts, "order:copytags_asc")
      assert_tag_match(posts, "order:note_count_asc")
      assert_tag_match(posts, "order:notes_asc")
    end

    should "return posts for order:comment_bumped" do
      post1 = FactoryBot.create(:post)
      post2 = FactoryBot.create(:post)
      post3 = FactoryBot.create(:post)

      CurrentUser.scoped(FactoryBot.create(:gold_user), "127.0.0.1") do
        comment1 = FactoryBot.create(:comment, :post => post1)
        comment2 = FactoryBot.create(:comment, :post => post2, :do_not_bump_post => true)
        comment3 = FactoryBot.create(:comment, :post => post3)
      end

      assert_tag_match([post3, post1, post2], "order:comment_bumped")
      assert_tag_match([post2, post1, post3], "order:comment_bumped_asc")
    end

    should "return posts for a filesize search" do
      post = FactoryBot.create(:post, :file_size => 1.megabyte)

      assert_tag_match([post], "filesize:1mb")
      assert_tag_match([post], "filesize:1000kb")
      assert_tag_match([post], "filesize:1048576b")
    end

    should "not perform fuzzy matching for an exact filesize search" do
      post = FactoryBot.create(:post, :file_size => 1.megabyte)

      assert_tag_match([], "filesize:1048000b")
      assert_tag_match([], "filesize:1048000")
    end

    should "resolve aliases to the actual tag" do
      create(:tag_alias, antecedent_name: "kitten", consequent_name: "cat")
      post1 = create(:post, tag_string: "cat")
      post2 = create(:post, tag_string: "dog")

      assert_tag_match([post1], "kitten")
      assert_tag_match([post2], "-kitten")
    end

    should "fail for more than 6 tags" do
      post1 = FactoryBot.create(:post, :rating => "s")

      assert_raise(::Post::SearchError) do
        Post.tag_match("a b c rating:s width:10 height:10 user:bob")
      end
    end

    should "not count free tags against the user's search limit" do
      post1 = FactoryBot.create(:post, tag_string: "aaa bbb rating:s")

      Danbooru.config.expects(:is_unlimited_tag?).with("rating:s").once.returns(true)
      Danbooru.config.expects(:is_unlimited_tag?).with(anything).twice.returns(false)
      assert_tag_match([post1], "aaa bbb rating:s")
    end

    should "succeed for exclusive tag searches with no other tag" do
      post1 = FactoryBot.create(:post, :rating => "s", :tag_string => "aaa")
      assert_nothing_raised do
        relation = Post.tag_match("-aaa")
      end
    end

    should "succeed for exclusive tag searches combined with a metatag" do
      post1 = FactoryBot.create(:post, :rating => "s", :tag_string => "aaa")
      assert_nothing_raised do
        relation = Post.tag_match("-aaa id:>0")
      end
    end
  end

  context "Voting:" do
    context "with a super voter" do
      setup do
        @user = FactoryBot.create(:user)
        FactoryBot.create(:super_voter, user: @user)
        @post = FactoryBot.create(:post)
      end
      
      should "account for magnitude" do
        CurrentUser.scoped(@user, "127.0.0.1") do
          assert_nothing_raised {@post.vote!("up")}
          assert_raises(PostVote::Error) {@post.vote!("up")}
          @post.reload
          assert_equal(1, PostVote.count)
          assert_equal(SuperVoter::MAGNITUDE, @post.score)
        end
      end
    end

    should "not allow members to vote" do
      @user = FactoryBot.create(:user)
      @post = FactoryBot.create(:post)
      as_user do
        assert_raises(PostVote::Error) { @post.vote!("up") }
      end
    end

    should "not allow duplicate votes" do
      user = FactoryBot.create(:gold_user)
      post = FactoryBot.create(:post)
      CurrentUser.scoped(user, "127.0.0.1") do
        assert_nothing_raised {post.vote!("up")}
        assert_raises(PostVote::Error) {post.vote!("up")}
        post.reload
        assert_equal(1, PostVote.count)
        assert_equal(1, post.score)
      end
    end

    should "allow undoing of votes" do
      user = FactoryBot.create(:gold_user)
      post = FactoryBot.create(:post)

      # We deliberately don't call post.reload until the end to verify that
      # post.unvote! returns the correct score even when not forcibly reloaded.
      CurrentUser.scoped(user, "127.0.0.1") do
        post.vote!("up")
        assert_equal(1, post.score)

        post.unvote!
        assert_equal(0, post.score)

        assert_nothing_raised {post.vote!("down")}
        assert_equal(-1, post.score)

        post.unvote!
        assert_equal(0, post.score)

        assert_nothing_raised {post.vote!("up")}
        assert_equal(1, post.score)

        post.reload
        assert_equal(1, post.score)
      end
    end
  end

  context "Counting:" do
    context "Creating a post" do
      setup do
        Danbooru.config.stubs(:blank_tag_search_fast_count).returns(nil)
        Danbooru.config.stubs(:estimate_post_counts).returns(false)
        FactoryBot.create(:tag_alias, :antecedent_name => "alias", :consequent_name => "aaa")
        FactoryBot.create(:post, :tag_string => "aaa", "score" => 42)
      end

      context "a single basic tag" do
        should "return the cached count" do
          Tag.find_or_create_by_name("aaa").update_columns(post_count: 100)
          assert_equal(100, Post.fast_count("aaa"))
        end
      end

      context "a single metatag" do
        should "return the correct cached count" do
          FactoryBot.build(:tag, name: "score:42", post_count: -100).save(validate: false)
          Post.set_count_in_cache("score:42", 100)

          assert_equal(100, Post.fast_count("score:42"))
        end

        should "return the correct cached count for a pool:<id> search" do
          FactoryBot.build(:tag, name: "pool:1234", post_count: -100).save(validate: false)
          Post.set_count_in_cache("pool:1234", 100)

          assert_equal(100, Post.fast_count("pool:1234"))
        end
      end

      context "a multi-tag search" do
        should "return the cached count, if it exists" do
          Post.set_count_in_cache("aaa score:42", 100)
          assert_equal(100, Post.fast_count("aaa score:42"))
        end

        should "return the true count, if not cached" do
          assert_equal(1, Post.fast_count("aaa score:42"))
        end

        should "set the expiration time" do
          Cache.expects(:put).with(Post.count_cache_key("aaa score:42"), 1, 180)
          Post.fast_count("aaa score:42")
        end
      end

      context "a blank search" do
        should "should execute a search" do
          Cache.delete(Post.count_cache_key(''))
          Post.expects(:fast_count_search).with("", kind_of(Hash)).once.returns(1)
          assert_equal(1, Post.fast_count(""))
        end

        should "set the value in cache" do
          Post.expects(:set_count_in_cache).with("", kind_of(Integer)).once
          Post.fast_count("")
        end

        context "with a primed cache" do
          setup do
            Cache.put(Post.count_cache_key(''), "100")
          end

          should "fetch the value from the cache" do
            assert_equal(100, Post.fast_count(""))
          end
        end

        should_eventually "translate an alias" do
          assert_equal(1, Post.fast_count("alias"))
        end

        should "return 0 for a nonexisting tag" do
          assert_equal(0, Post.fast_count("bbb"))
        end

        context "in safe mode" do
          setup do
            CurrentUser.stubs(:safe_mode?).returns(true)
            FactoryBot.create(:post, "rating" => "s")
          end

          should "work for a blank search" do
            assert_equal(1, Post.fast_count(""))
          end

          should "work for a nil search" do
            assert_equal(1, Post.fast_count(nil))
          end

          should "not fail for a two tag search by a member" do
            post1 = FactoryBot.create(:post, tag_string: "aaa bbb rating:s")
            post2 = FactoryBot.create(:post, tag_string: "aaa bbb rating:e")

            Danbooru.config.expects(:is_unlimited_tag?).with("rating:s").once.returns(true)
            Danbooru.config.expects(:is_unlimited_tag?).with(anything).twice.returns(false)
            assert_equal(1, Post.fast_count("aaa bbb"))
          end

          should "set the value in cache" do
            Post.expects(:set_count_in_cache).with("rating:s", kind_of(Integer)).once
            Post.fast_count("")
          end

          context "with a primed cache" do
            setup do
              Cache.put(Post.count_cache_key('rating:s'), "100")
            end

            should "fetch the value from the cache" do
              assert_equal(100, Post.fast_count(""))
            end
          end
        end
      end
    end
  end

  context "Reverting: " do
    context "a post that is rating locked" do
      setup do
        @post = FactoryBot.create(:post, :rating => "s")
        travel(2.hours) do
          @post.update(rating: "q", is_rating_locked: true)
        end
      end

      should "not revert the rating" do
        assert_raises ActiveRecord::RecordInvalid do
          @post.revert_to!(@post.versions.first)
        end

        assert_equal(["Rating is locked and cannot be changed. Unlock the post first."], @post.errors.full_messages)
        assert_equal(@post.versions.last.rating, @post.reload.rating)
      end

      should "revert the rating after unlocking" do
        @post.update(rating: "e", is_rating_locked: false)
        assert_nothing_raised do
          @post.revert_to!(@post.versions.first)
        end

        assert(@post.valid?)
        assert_equal(@post.versions.first.rating, @post.rating)
      end
    end

    context "a post that has been updated" do
      setup do
        PostArchive.sqs_service.stubs(:merge?).returns(false)
        @post = FactoryBot.create(:post, :rating => "q", :tag_string => "aaa", :source => "")
        @post.reload
        @post.update(:tag_string => "aaa bbb ccc ddd")
        @post.reload
        @post.update(:tag_string => "bbb xxx yyy", :source => "xyz")
        @post.reload
        @post.update(:tag_string => "bbb mmm yyy", :source => "abc")
        @post.reload
      end

      context "and then reverted to an early version" do
        setup do
          @post.revert_to(@post.versions[1])
        end

        should "correctly revert all fields" do
          assert_equal("aaa bbb ccc ddd", @post.tag_string)
          assert_equal("", @post.source)
          assert_equal("q", @post.rating)
        end
      end

      context "and then reverted to a later version" do
        setup do
          @post.revert_to(@post.versions[-2])
        end

        should "correctly revert all fields" do
          assert_equal("bbb xxx yyy", @post.tag_string)
          assert_equal("xyz", @post.source)
          assert_equal("q", @post.rating)
        end
      end
    end
  end

  context "URLs:" do
    should "generate the correct urls for animated gifs" do
      @post = FactoryBot.build(:post, md5: "deadbeef", file_ext: "gif", tag_string: "animated_gif")

      assert_equal("https://#{Socket.gethostname}/data/preview/deadbeef.jpg", @post.preview_file_url)
      assert_equal("https://#{Socket.gethostname}/data/deadbeef.gif", @post.large_file_url)
      assert_equal("https://#{Socket.gethostname}/data/deadbeef.gif", @post.file_url)
    end
  end

  context "Notes:" do
    context "#copy_notes_to" do
      setup do
        @src = FactoryBot.create(:post, image_width: 100, image_height: 100, tag_string: "translated partially_translated", has_embedded_notes: true)
        @dst = FactoryBot.create(:post, image_width: 200, image_height: 200, tag_string: "translation_request")

        @src.notes.create(x: 10, y: 10, width: 10, height: 10, body: "test")
        @src.notes.create(x: 10, y: 10, width: 10, height: 10, body: "deleted", is_active: false)
        @src.reload

        @src.copy_notes_to(@dst)
      end

      should "copy notes and tags" do
        assert_equal(1, @dst.notes.active.length)
        assert_equal(true, @dst.has_embedded_notes)
        assert_equal("lowres partially_translated translated", @dst.tag_string)
      end

      should "rescale notes" do
        note = @dst.notes.active.first
        assert_equal([20, 20, 20, 20], [note.x, note.y, note.width, note.height])
      end
    end
  end

  context "#replace!" do
    subject { @post.replace!(tags: "something", replacement_url: "https://danbooru.donmai.us/images/download-preview.png") }

    setup do
      @post = FactoryBot.create(:post)
      @post.stubs(:queue_delete_files)
    end

    should "update the post" do
      assert_changes(-> { @post.md5 }) do
        subject
      end
    end
  end
end
