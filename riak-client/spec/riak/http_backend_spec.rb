require 'spec_helper'

describe Riak::Client::HTTPBackend do
  before :each do
    @client = Riak::Client.new
    @backend = Riak::Client::HTTPBackend.new(@client)
    @backend.instance_variable_set(:@server_config, {})
  end

  it "should take the Riak::Client when creating" do
    lambda { Riak::Client::HTTPBackend.new(nil) }.should raise_error(ArgumentError)
    lambda { Riak::Client::HTTPBackend.new(@client) }.should_not raise_error
  end

  it "should make the client accessible" do
    @backend.client.should == @client
  end

  context "pinging the server" do
    it "should succeed on 200" do
      @backend.should_receive(:get).with(200, @backend.ping_path).and_return({:code => 200, :body => "OK"})
      @backend.ping.should be_true
    end

    it "should fail on any other code or error" do
      @backend.should_receive(:get).and_raise("socket closed")
      @backend.ping.should be_false
    end
  end

  context "fetching an object" do
    it "should perform a GET request and return an RObject" do
      @backend.should_receive(:get).with([200,300], @backend.object_path('foo', 'db')).and_return({:headers => {"content-type" => ["application/json"]}, :body => '{"name":"Riak","company":"Basho"}'})
      @backend.fetch_object("foo", "db").should be_kind_of(Riak::RObject)
    end

    it "should pass the R quorum as a query parameter" do
      @backend.should_receive(:get).with([200,300], @backend.object_path("foo", "db", {:r => 2})).and_return({:headers => {"content-type" => ["application/json"]}, :body => '{"name":"Riak","company":"Basho"}'})
      @backend.fetch_object("foo", "db", :r => 2)
    end

    it "should escape the bucket and key names" do
      @backend.should_receive(:get).with([200,300], @backend.object_path('foo ', ' bar')).and_return({:headers => {"content-type" => ["application/json"]}, :body => '{"name":"Riak","company":"Basho"}'})
      @backend.fetch_object('foo ',' bar').should be_kind_of(Riak::RObject)
    end
  end

  context "reloading an object" do
    before do
      @object = Riak::RObject.new(@client.bucket("foo"), "bar")
    end

    it "should use conditional request headers" do
      @object.etag = "etag"
      @backend.should_receive(:get).with([200,300,304], @backend.object_path('foo', 'bar'), {'If-None-Match' => "etag"}).and_return({:code => 304})
      @backend.reload_object(@object)
    end

    it "should return without modifying the object if the response is 304 Not Modified" do
      @backend.should_receive(:get).and_return({:code => 304})
      @backend.should_not_receive(:load_object)
      @backend.reload_object(@object)
    end

    it "should raise an exception when the response code is not 200 or 304" do
      @backend.should_receive(:get).and_raise(Riak::HTTPFailedRequest.new(:get, 200, 500, {}, ''))
      lambda { @backend.reload_object(@object) }.should raise_error(Riak::FailedRequest)
    end

    it "should escape the bucket and key names" do
      # @bucket.should_receive(:name).and_return("some/deep/path")
      @object.bucket = @client.bucket("some/deep/path")
      @object.key = "another/deep/path"
      @backend.should_receive(:get).with([200,300,304], @backend.object_path(@object.bucket.name, @object.key), {}).and_return({:code => 304})
      @backend.reload_object(@object)
    end
  end

  context "storing an object" do
    before do
      @bucket = Riak::Bucket.new(@client, "foo")
      @object = Riak::RObject.new(@bucket)
      @object.content_type = "text/plain"
      @object.data = "This is some text."
      @headers = @backend.store_headers(@object)
    end

    it "should use the raw_data as the request body" do
      @object.content_type = "application/json"
      body = @object.raw_data = "{this is probably invalid json!}}"
      @backend.stub(:post).and_return({})
      @object.should_not_receive(:serialize)
      @backend.store_object(@object, :returnbody => false)
    end
    
    context "when the object has no key" do
      it "should issue a POST request to the bucket, and update the object properties (returning the body by default)" do
        @backend.should_receive(:post).with(201, @backend.object_path("foo", nil, {:returnbody => true}), "This is some text.", @headers).and_return({:headers => {'location' => ["/riak/foo/somereallylongstring"], "x-riak-vclock" => ["areallylonghashvalue"]}, :code => 201})
        @backend.store_object(@object, :returnbody => true)
        @object.key.should == "somereallylongstring"
        @object.vclock.should == "areallylonghashvalue"
      end

      it "should include persistence-tuning parameters in the query string" do
        @backend.should_receive(:post).with(201, @backend.object_path("foo", nil, {:dw => 2, :returnbody => true}), "This is some text.", @headers).and_return({:headers => {'location' => ["/riak/foo/somereallylongstring"], "x-riak-vclock" => ["areallylonghashvalue"]}, :code => 201})
        @backend.store_object(@object, :returnbody => true, :dw => 2)
      end
    end

    context "when the object has a key" do
      before :each do
        @object.key = "bar"
      end

      it "should issue a PUT request to the bucket, and update the object properties (returning the body by default)" do
        @backend.should_receive(:put).with([200,204,300], @backend.object_path("foo", "bar", {:returnbody => true}), "This is some text.", @headers).and_return({:headers => {'location' => ["/riak/foo/somereallylongstring"], "x-riak-vclock" => ["areallylonghashvalue"]}, :code => 204})
        @backend.store_object(@object, :returnbody => true)
        @object.key.should == "somereallylongstring"
        @object.vclock.should == "areallylonghashvalue"
      end
      
      it "should include persistence-tuning parameters in the query string" do
        @backend.should_receive(:put).with([200,204,300], @backend.object_path("foo", "bar", {:w => 2, :returnbody => true}), "This is some text.", @headers).and_return({:headers => {'location' => ["/riak/foo/somereallylongstring"], "x-riak-vclock" => ["areallylonghashvalue"]}, :code => 204})
        @backend.store_object(@object, :returnbody => true, :w => 2)
      end
    end
  end

  context "deleting an object" do
    it "should perform a DELETE request" do
      @backend.should_receive(:delete).with([204,404], @backend.object_path("foo", 'bar'), {}).and_return(:code => 204)
      @backend.delete_object("foo", "bar")
    end

    it "should perform a DELETE request with the provided vclock" do
      @backend.should_receive(:delete).with([204,404], @backend.object_path("foo", 'bar'), {'X-Riak-VClock' => "myvclock"}).and_return(:code => 204)
      @backend.delete_object('foo', 'bar', :vclock => "myvclock")
    end

    it "should perform a DELETE request with the requested quorum value" do
      @backend.should_receive(:delete).with([204,404], @backend.object_path("foo", 'bar', {:rw => 2}), {'X-Riak-VClock' => "myvclock"}).and_return(:code => 204)
      @backend.delete_object('foo', 'bar', :vclock => "myvclock", :rw => 2)
    end    
  end

  context "fetching bucket properties" do
    it "should GET the bucket URL and parse the response as JSON" do
      @backend.should_receive(:get).with(200, @backend.bucket_properties_path('foo')).and_return({:body => '{"props":{"n_val":3}}'})
      @backend.get_bucket_props("foo").should == {"n_val" => 3}
    end
  end
  
  context "setting bucket properties" do
    it "should PUT the properties to the bucket URL as JSON" do
      @backend.should_receive(:put).with(204, @backend.bucket_properties_path('foo'), '{"props":{"n_val":2}}', {"Content-Type" => "application/json"}).and_return({:body => "", :headers => {}})
      @backend.set_bucket_props("foo", {:n_val => 2})      
    end
  end
  
  context "listing keys" do
    it "should unescape key names" do
      @backend.should_receive(:get).with(200, @backend.key_list_path('foo')).and_return({:headers => {"content-type" => ["application/json"]}, :body => '{"keys":["bar%20baz"]}'})
      @backend.list_keys("foo").should == ["bar baz"]
    end
  end

  context "listing buckets" do
    it "should GET the bucket list URL and parse the response as JSON" do
      @backend.should_receive(:get).with(200, @backend.bucket_list_path).and_return({:body => '{"buckets":["foo", "bar", "baz"]}'})
      @backend.list_buckets.should == ["foo", "bar", "baz"]
    end
  end
  
  context "performing a MapReduce query" do
    before do
      @mr = Riak::MapReduce.new(@client).map("Riak.mapValues", :keep => true)
    end

    it "should issue POST request to the mapred endpoint" do
      @backend.should_receive(:post).with(200, @backend.mapred_path, @mr.to_json, hash_including("Content-Type" => "application/json")).and_return({:headers => {'content-type' => ["application/json"]}, :body => "[]"})
      @backend.mapred(@mr)
    end

    it "should vivify JSON responses" do
      @backend.stub!(:post).and_return(:headers => {'content-type' => ["application/json"]}, :body => '[{"key":"value"}]')
      @backend.mapred(@mr).should == [{"key" => "value"}]
    end

    it "should return the full response hash for non-JSON responses" do
      response = {:code => 200, :headers => {'content-type' => ["text/plain"]}, :body => 'This is some text.'}
      @backend.stub!(:post).and_return(response)
      @backend.mapred(@mr).should == response
    end

    it "should stream results through the block" do
      data = File.read("spec/fixtures/multipart-mapreduce.txt")
      @backend.should_receive(:post).with(200, @backend.mapred_path(:chunked => true), @mr.to_json, hash_including("Content-Type" => "application/json")).and_yield(data)
      block = mock
      block.should_receive(:ping).twice.and_return(true)
      @backend.mapred(@mr) do |phase, data|
        block.ping
        phase.should == 0
        data.should have(1).item
      end
    end
  end

  context "getting statistics" do
    it "should get the status URL and parse the response as JSON" do
      @backend.should_receive(:get).with(200, @backend.stats_path).and_return({:body => '{"vnode_gets":20348}'})
      @backend.stats.should == {"vnode_gets" => 20348}
    end
  end
  
  context "performing a link-walking query" do
    before do
      @bucket = Riak::Bucket.new(@client, "foo")
      @object = Riak::RObject.new(@bucket, "bar")
      @body = File.read(File.expand_path("#{File.dirname(__FILE__)}/../fixtures/multipart-with-body.txt"))
      @specs = [Riak::WalkSpec.new(:tag => "next", :keep => true)]
    end

    it "should perform a GET request for the given object and walk specs" do
      @backend.should_receive(:get).with(200, @backend.link_walk_path(@bucket.name, @object.key, @specs)).and_return(:headers => {"content-type" => ["multipart/mixed; boundary=12345"]}, :body => "\n--12345\nContent-Type: multipart/mixed; boundary=09876\n\n--09876--\n\n--12345--\n")
      @backend.link_walk(@object, @specs)
    end

    it "should parse the results into arrays of objects" do
      @backend.should_receive(:get).and_return(:headers => {"content-type" => ["multipart/mixed; boundary=5EiMOjuGavQ2IbXAqsJPLLfJNlA"]}, :body => @body)
      results = @backend.link_walk(@object, @specs)
      results.should be_kind_of(Array)
      results.first.should be_kind_of(Array)
      obj = results.first.first
      obj.should be_kind_of(Riak::RObject)
      obj.content_type.should == "text/plain"
      obj.key.should == "baz"
      obj.bucket.should == @bucket
    end

    it "should assign the bucket for newly parsed objects" do
      @backend.stub!(:get).and_return(:headers => {"content-type" => ["multipart/mixed; boundary=5EiMOjuGavQ2IbXAqsJPLLfJNlA"]}, :body => @body)
      @client.should_receive(:bucket).with("foo").and_return(@bucket)
      @backend.link_walk(@object, @specs)
    end
  end
end
