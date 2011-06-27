package Carton::CLI;
use strict;
use warnings;

use Carton;
use Carton::Util;

use Cwd;
use Config;
use Getopt::Long;
use Term::ANSIColor qw(colored);

use Carton::Tree;
use Try::Tiny;

use constant { SUCCESS => 0, WARN => 1, INFO => 2, ERROR => 3 };

our $Colors = {
    SUCCESS() => 'green',
    WARN()    => 'yellow',
    INFO()    => 'cyan',
    ERROR()   => 'red',
};

sub new {
    my $class = shift;
    bless {
        path  => 'local',
        color => 1,
        verbose => 0,
        carton => Carton->new,
    }, $class;
}

sub carton { $_[0]->{carton} }

sub work_file {
    my($self, $file) = @_;
    return "$self->{work_dir}/$file";
}

sub run {
    my($self, @args) = @_;

    $self->{work_dir} = $ENV{PERL_CARTON_HOME} || (Cwd::cwd() . "/.carton");
    mkdir $self->{work_dir}, 0777 unless -e $self->{work_dir};

    local @ARGV = @args;
    my @commands;
    my $p = Getopt::Long::Parser->new(
        config => [ "no_ignore_case", "pass_through" ],
    );
    $p->getoptions(
        "h|help"    => sub { unshift @commands, 'help' },
        "v|version" => sub { unshift @commands, 'version' },
        "color!"    => \$self->{color},
        "verbose!"  => \$self->{verbose},
    );

    push @commands, @ARGV;

    my $cmd = shift @commands || 'usage';
    my $call = $self->can("cmd_$cmd");

    if ($call) {
        $self->$call(@commands);
    } else {
        die "Could not find command '$cmd'\n";
    }
}

sub commands {
    my $self = shift;

    no strict 'refs';
    map { s/^cmd_//; $_ }
        grep /^cmd_(.*)/, sort keys %{__PACKAGE__."::"};
}

sub cmd_usage {
    my $self = shift;
    $self->print(<<HELP);
Usage: carton <command>

where <command> is one of:
  @{[ join ", ", $self->commands ]}

Run carton -h <command> for help.
HELP
}

sub parse_options {
    my($self, $args, @spec) = @_;
    Getopt::Long::GetOptionsFromArray($args, @spec);
}

sub print {
    my($self, $msg, $type) = @_;
    $msg = colored $msg, $Colors->{$type} if defined $type && $self->{color};
    print $msg;
}

sub error {
    my($self, $msg) = @_;
    $self->print($msg, ERROR);
    exit(1);
}

sub cmd_help {
    my $self = shift;
    my $module = $_[0] ? ("Carton::Doc::" . ucfirst $_[0]) : "Carton";
    system "perldoc", $module;
}

sub cmd_version {
    my $self = shift;
    $self->print("carton $Carton::VERSION\n");
}

sub cmd_install {
    my($self, @args) = @_;

    $self->parse_options(\@args, "p|path=s", \$self->{path}, "deployment!" => \$self->{deployment});

    my $lock = $self->find_lock;

    $self->carton->configure(
        path => $self->{path},
        lock => $lock,
        mirror_file => $self->mirror_file, # $lock object?
    );

    my $build_file = $self->has_build_file;

    if (@args) {
        $self->print("Installing modules from the command line\n");
        $self->carton->install_modules(\@args);
        $self->carton->update_lock_file($self->lock_file);
    } elsif ($self->{deployment} or not $build_file) {
        $self->print("Installing modules using carton.lock (deployment mode)\n");
        $self->carton->install_from_lock;
    } elsif ($build_file) {
        $self->print("Installing modules using $build_file\n");
        $self->carton->install_from_build_file($build_file);
        $self->carton->update_lock_file($self->lock_file);
    } else {
        $self->error("Can't locate build file or carton.lock\n");
    }

    $self->print("Complete! Modules were installed into $self->{path}\n", SUCCESS);
}

sub mirror_file {
    my $self = shift;
    return $self->work_file("02packages.details.txt");
}

sub has_build_file {
    my $self = shift;

    my $file = (grep -e, qw( Build.PL Makefile.PL ))[0]
        or return;

    return $file;
}

*cmd_list = \&cmd_show;

sub cmd_show {
    my($self, @args) = @_;

    my $tree_mode;
    $self->parse_options(\@args, "tree!" => \$tree_mode);

    my $lock = $self->lock_data
        or $self->error("Can't find carton.lock: Run `carton install` to rebuild the spec file.\n");

    if ($tree_mode) {
        my $tree = $self->carton->build_tree($lock->{modules});
        $self->carton->walk_down_tree($tree, sub {
            my($module, $depth) = @_;
            my $line = " " x $depth . "$module->{dist}\n";
            $self->print($line);
        });
    } else {
        for my $module (values %{$lock->{modules} || {}}) {
            $self->print("$module->{dist}\n");
        }
    }
}

sub cmd_check {
    my($self, @args) = @_;

    my $file = $self->has_build_file
        or $self->error("Can't find a build file: nothing to check.\n");

    $self->parse_options(\@args, "p|path=s", \$self->{path});
    $self->carton->configure(
        path => $self->{path},
    );

    my $lock = $self->carton->build_lock;
    my @deps = $self->carton->list_dependencies;

    my $res = $self->carton->check_satisfies($lock, \@deps);

    my $ok = 1;
    if (@{$res->{unsatisfied}}) {
        $self->print("Following dependencies are not satisfied. Run `carton install` to install them.\n", WARN);
        for my $dep (@{$res->{unsatisfied}}) {
            $self->print("$dep->{module} " . ($dep->{version} ? "($dep->{version})" : "") . "\n");
        }
        $ok = 0;
    }

    if ($res->{superflous}) {
        $self->print("Following modules are found in $self->{path} but couldn't be tracked from your $file\n", WARN);
        $self->carton->walk_down_tree($res->{superflous}, sub {
            my($module, $depth) = @_;
            my $line = "  " x $depth . "$module->{dist}\n";
            $self->print($line);
        }, 1);
        $ok = 0;
    }

    if ($ok) {
        $self->print("Dependencies specified in your $file are satisfied and matches with modules in $self->{path}.\n", SUCCESS);
    }
}

sub cmd_update {
    # "cleanly" update distributions in extlib
    # rebuild the tree, update modules with DFS
}

sub cmd_exec {
    # setup lib::core::only, -L env, put extlib/bin into PATH and exec script
}

sub find_lock {
    my $self = shift;

    if (-e $self->lock_file) {
        return $self->lock_data; # TODO object
    }

    return;
}

sub lock_data {
    my $self = shift;

    return $self->{lock} if $self->{lock};

    try {
        my $lock = Carton::Util::parse_json($self->lock_file);
        $self->{lock} = $lock;
    } catch {
        if (/No such file/) {
            $self->error("Can't locate carton.lock\n");
        } else {
            $self->error("Can't parse carton.lock: $_\n");
        }
    };

    return $self->{lock};
}

sub lock_file {
    my $self = shift;
    return 'carton.lock';
}


1;
