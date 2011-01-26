require "spec_helper"
require "fileutils"

describe Bosh::Cli::JobBuilder do

  before(:each) do
    @release_dir = Dir.mktmpdir
  end

  def new_builder(name, packages = [], configs = { }, built_packages = [], create_spec = true)
    # Workaround for Hash requirement
    if configs.is_a?(Array)
      configs = configs.inject({ }) { |h, e| h[e] = 1; h }
    end
    
    spec = {
      "name"          => name,
      "packages"      => packages,
      "configuration" => configs
    }
    add_spec(name) if create_spec

    blobstore = mock("blobstore")
    Bosh::Cli::JobBuilder.new(spec, @release_dir, false, blobstore, built_packages)
  end

  def add_file(job_name, file, contents = nil)
    job_dir = File.join(@release_dir, "jobs", job_name)
    FileUtils.mkdir_p(job_dir)
    FileUtils.touch(File.join(job_dir, file))
    if contents
      File.open(File.join(job_dir, file), "w") { |f| f.write(contents) }
    end
  end

  def add_spec(job_name)
    add_file(job_name, "spec")
  end  

  def add_monit(job_name)
    add_file(job_name, "monit")
  end

  def add_configs(job_name, *files)
    job_config_path = File.join(@release_dir, "jobs", job_name, "config")
    FileUtils.mkdir_p(job_config_path)

    files.each do |file|
      add_file(job_name, "config/#{file}")
    end
  end

  it "creates a new builder" do
    add_configs("foo", "a.conf", "b.yml")
    add_monit("foo")
    builder = new_builder("foo", ["foo", "bar", "baz"], ["a.conf", "b.yml"], ["foo", "bar", "baz"])
    builder.packages.should    == ["foo", "bar", "baz"]
    builder.configs.should     =~ ["a.conf", "b.yml"]
    builder.release_dir.should == @release_dir
  end

  it "has a fingerprint" do
    add_configs("foo", "a.conf", "b.yml")
    add_monit("foo")
    builder = new_builder("foo", ["foo", "bar"], ["a.conf", "b.yml"], ["foo", "bar"])
    builder.fingerprint.should == "8c648313f029ee50612bfbb99b507eef1eb6f6c0"
  end

  it "has a stable portable fingerprint" do
    add_configs("foo", "a.conf", "b.yml")
    add_monit("foo")
    b1 = new_builder("foo", ["foo", "bar"], ["a.conf", "b.yml"], ["foo", "bar"])
    f1 = b1.fingerprint
    b1.reload.fingerprint.should == f1

    b2 = new_builder("foo", ["foo", "bar"], ["a.conf", "b.yml"], ["foo", "bar"])
    b2.fingerprint.should == f1
  end

  it "changes fingerprint when new config file is added" do
    add_configs("foo", "a.conf", "b.yml")
    add_monit("foo")

    b1 = new_builder("foo", ["foo", "bar"], ["a.conf", "b.yml"], ["foo", "bar"])    
    f1 = b1.fingerprint

    add_configs("foo", "baz")
    b2 = new_builder("foo", ["foo", "bar"], ["a.conf", "b.yml", "baz"], ["foo", "bar"])
    b2.fingerprint.should_not == f1
  end

  it "changes fingerprint when config files is changed" do
    add_configs("foo", "a.conf", "b.yml")
    add_monit("foo")

    b1 = new_builder("foo", ["foo", "bar"], ["a.conf", "b.yml"], ["foo", "bar"])    
    f1 = b1.fingerprint

    add_file("foo", "config/a.conf", "bzz")
    b1.reload.fingerprint.should_not == f1
  end  

  it "can read config file names from hash" do
    add_configs("foo", "a.conf", "b.yml")
    add_monit("foo")
    builder = new_builder("foo", ["foo", "bar", "baz"], {"a.conf" => 1, "b.yml" => 2}, ["foo", "bar", "baz"])
    builder.configs.should =~ ["a.conf", "b.yml"]
  end

  it "whines if name is blank" do
    lambda {
      new_builder("")
    }.should raise_error(Bosh::Cli::InvalidJob, "Job name is missing")
  end

  it "whines on funny characters in name" do
    lambda {
      new_builder("@#!", [])
    }.should raise_error(Bosh::Cli::InvalidJob, "`@#!' is not a valid Bosh identifier")
  end  

  it "whines if some configs are missing" do
    add_configs("foo", "a.conf", "b.conf")

    lambda {
      new_builder("foo", [], ["a.conf", "b.conf", "c.conf"])      
    }.should raise_error(Bosh::Cli::InvalidJob, "Some config files required by 'foo' job are missing: c.conf")
  end  

  it "whines if some packages are missing" do
    lambda {
      new_builder("foo", ["foo", "bar", "baz", "app42"], { }, ["foo", "bar"])      
    }.should raise_error(Bosh::Cli::InvalidJob, "Some packages required by 'foo' job are missing: baz, app42")
  end

  it "whines if there is no spec file" do
    lambda {
      new_builder("foo", ["foo", "bar", "baz", "app42"], { }, ["foo", "bar", "baz", "app42"], false)
    }.should raise_error(Bosh::Cli::InvalidJob, "Cannot find spec file for 'foo'")
  end

  it "whines if there is no monit file" do
    lambda {
      add_configs("foo", "a.conf", "b.yml")
      new_builder("foo", ["foo", "bar", "baz", "app42"], ["a.conf", "b.yml"], ["foo", "bar", "baz", "app42"])
    }.should raise_error(Bosh::Cli::InvalidJob, "Cannot find monit file for 'foo'")

    add_monit("foo")
    lambda {
      new_builder("foo", ["foo", "bar", "baz", "app42"], ["a.conf", "b.yml"], ["foo", "bar", "baz", "app42"])      
    }.should_not raise_error
  end

  it "copies job files" do
    add_configs("foo", "a.conf", "b.yml")
    add_monit("foo")    
    builder = new_builder("foo", ["foo", "bar", "baz", "app42"], ["a.conf", "b.yml"], ["foo", "bar", "baz", "app42"])

    builder.copy_files.should == 4

    Dir.chdir(builder.build_dir) do
      File.directory?("config").should be_true
      ["config/a.conf", "config/b.yml"].each do |file|
        File.file?(file).should be_true
      end
      File.file?("job.MF").should be_true
      File.read("job.MF").should == File.read(File.join(@release_dir, "jobs", "foo", "spec"))
      File.exists?("monit").should be_true
    end
  end

  it "generates tarball" do
    add_configs("foo", "bar", "baz")
    add_monit("foo")

    builder = new_builder("foo", ["p1", "p2"], ["bar", "baz"], ["p1", "p2"])
    builder.generate_tarball.should be_true
  end

  it "supports versioning" do
    add_configs("foo", "bar", "baz")
    add_monit("foo")

    builder = new_builder("foo", [], ["bar", "baz"], [])

    File.exists?(@release_dir + "/jobs/foo/dev_builds/1.tgz").should be_false
    builder.build
    File.exists?(@release_dir + "/jobs/foo/dev_builds/1.tgz").should be_true
    v1_fingerprint = builder.fingerprint    

    add_configs("foo", "zb.yml")
    builder = new_builder("foo", [], ["bar", "baz", "zb.yml"], [])
    builder.build

    File.exists?(@release_dir + "/jobs/foo/dev_builds/1.tgz").should be_true
    File.exists?(@release_dir + "/jobs/foo/dev_builds/2.tgz").should be_true

    builder = new_builder("foo", [], ["bar", "baz"], [])
    builder.build
    builder.version.should == 1

    builder.fingerprint.should == v1_fingerprint    
    File.exists?(@release_dir + "/jobs/foo/dev_builds/1.tgz").should be_true
    File.exists?(@release_dir + "/jobs/foo/dev_builds/2.tgz").should be_true
    File.exists?(@release_dir + "/jobs/foo/dev_builds/3.tgz").should be_false    
  end
  
end
