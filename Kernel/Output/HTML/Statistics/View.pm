# --
# Copyright (C) 2001-2016 OTRS AG, http://otrs.com/
# --
# This software comes with ABSOLUTELY NO WARRANTY. For details, see
# the enclosed file COPYING for license information (AGPL). If you
# did not receive this file, see http://www.gnu.org/licenses/agpl.txt.
# --

package Kernel::Output::HTML::Statistics::View;

## nofilter(TidyAll::Plugin::OTRS::Perl::PodChecker)

use strict;
use warnings;

use List::Util qw( first );

use Kernel::System::VariableCheck qw(:all);

our @ObjectDependencies = (
    'Kernel::Config',
    'Kernel::Language',
    'Kernel::Output::HTML::Layout',
    'Kernel::Output::PDF::Statistics',
    'Kernel::System::CSV',
    'Kernel::System::Group',
    'Kernel::System::Log',
    'Kernel::System::Main',
    'Kernel::System::PDF',
    'Kernel::System::Stats',
    'Kernel::System::Ticket',
    'Kernel::System::Time',
    'Kernel::System::User',
    'Kernel::System::Web::Request',
);

use Kernel::Language qw(Translatable);

=head1 NAME

Kernel::Output::HTML::Statistics::View - View object for statistics

=head1 SYNOPSIS

Provides several functions to generate statistics GUI elements.

=head1 PUBLIC INTERFACE

=over 4

=cut

sub new {
    my ( $Type, %Param ) = @_;

    # allocate new hash for object
    my $Self = {};
    bless( $Self, $Type );

    return $Self;
}

=item StatsParamsWidget()

generate HTML for statistics run widget.

    my $HTML = $StatsViewObject->StatsParamsWidget(
        StatID => $StatID,

        Formats => {            # optional, limit the available formats
            Print => 'Print',
        }

        OutputCounter => 1,     # optional, counter to append to ElementIDs
                                # This is needed if there is more than one stat on the page.

        AJAX          => 0,     # optional, keep script tags for AJAX responses
    );

=cut

sub StatsParamsWidget {
    my ( $Self, %Param ) = @_;

    my $LayoutObject = $Kernel::OM->Get('Kernel::Output::HTML::Layout');
    my $ConfigObject = $Kernel::OM->Get('Kernel::Config');
    my $ParamObject  = $Kernel::OM->Get('Kernel::System::Web::Request');

    for my $Needed (qw(Stat)) {
        if ( !$Param{$Needed} ) {
            $Kernel::OM->Get('Kernel::System::Log')->Log(
                Priority => "error",
                Message  => "Need $Needed!"
            );
            return;
        }
    }

    # Don't allow to run an invalid stat.
    return if !$Param{Stat}->{Valid};

    $Param{OutputCounter} ||= 1;

    # Check if there are any configuration errors that must be corrected by the stats admin
    my $StatsConfigurationValid = $Self->StatsConfigurationValidate(
        Stat   => $Param{Stat},
        Errors => {},
    );

    if ( !$StatsConfigurationValid ) {
        return;
    }

    my $HasUserGetParam = ref $Param{UserGetParam} eq 'HASH';

    my %UserGetParam = %{ $Param{UserGetParam} // {} };
    my $Format = $Param{Formats} || $ConfigObject->Get('Stats::Format');

    my $LocalGetParam = sub {
        my (%Param) = @_;
        my $Param = $Param{Param};
        return $HasUserGetParam ? $UserGetParam{$Param} : $ParamObject->GetParam( Param => $Param );
    };

    my $LocalGetArray = sub {
        my (%Param) = @_;
        my $Param = $Param{Param};
        if ($HasUserGetParam) {
            if ( $UserGetParam{$Param} && ref $UserGetParam{$Param} eq 'ARRAY' ) {
                return @{ $UserGetParam{$Param} };
            }
            return;
        }
        return $ParamObject->GetArray( Param => $Param );
    };

    my $Stat   = $Param{Stat};
    my $StatID = $Stat->{StatID};

    my $Output;

    # get the object name
    if ( $Stat->{StatType} eq 'static' ) {
        $Stat->{ObjectName} = $Stat->{File};
    }

    # if no object name is defined use an empty string
    $Stat->{ObjectName} ||= '';

    # create format select box
    my %SelectFormat;
    VALUE:
    for my $Value ( @{ $Stat->{Format} } ) {
        next VALUE if !defined $Format->{$Value};
        $SelectFormat{$Value} = $Format->{$Value};
    }

    if ( keys %SelectFormat > 1 ) {
        my %Frontend;
        $Frontend{SelectFormat} = $LayoutObject->BuildSelection(
            Data       => \%SelectFormat,
            SelectedID => $LocalGetParam->( Param => 'Format' ),
            Name       => 'Format',
            Class      => 'Modernize',
        );
        $LayoutObject->Block(
            Name => 'Format',
            Data => \%Frontend,
        );
    }
    elsif ( keys %SelectFormat == 1 ) {
        $LayoutObject->Block(
            Name => 'FormatFixed',
            Data => {
                Format    => ( values %SelectFormat )[0],
                FormatKey => ( keys %SelectFormat )[0],
            },
        );
    }
    else {
        return;    # no possible output format
    }

# provide the time zone field only, if the system use UTC as system time, the TimeZoneUser is active and for dynamic statistics
    if (
        !$Kernel::OM->Get('Kernel::System::Time')->ServerLocalTimeOffsetSeconds()
        && $ConfigObject->Get('TimeZoneUser')
        && $Stat->{StatType} eq 'dynamic'
        )
    {
        my %TimeZoneBuildSelection = $Self->_TimeZoneBuildSelection();

        my %Frontend;
        $Frontend{SelectTimeZone} = $LayoutObject->BuildSelection(
            %TimeZoneBuildSelection,
            Name       => 'TimeZone',
            Class      => 'Modernize',
            SelectedID => $LocalGetParam->( Param => 'TimeZone' ) // $Stat->{TimeZone}
                // $ConfigObject->Get('TimeZone') || 0,
        );

        $LayoutObject->Block(
            Name => 'TimeZone',
            Data => \%Frontend,
        );
    }

    if ( $ConfigObject->Get('Stats::ExchangeAxis') ) {
        my $ExchangeAxis = $LayoutObject->BuildSelection(
            Data => {
                1 => 'Yes',
                0 => 'No'
            },
            Name       => 'ExchangeAxis',
            SelectedID => $LocalGetParam->( Param => 'ExchangeAxis' ) // 0,
            Class      => 'Modernize',
        );

        $LayoutObject->Block(
            Name => 'ExchangeAxis',
            Data => { ExchangeAxis => $ExchangeAxis }
        );
    }

    # get static attributes
    if ( $Stat->{StatType} eq 'static' ) {

        # load static module
        my $Params = $Kernel::OM->Get('Kernel::System::Stats')->GetParams( StatID => $StatID );
        $LayoutObject->Block(
            Name => 'Static',
        );
        PARAMITEM:
        for my $ParamItem ( @{$Params} ) {
            $LayoutObject->Block(
                Name => 'ItemParam',
                Data => {
                    Param => $ParamItem->{Frontend},
                    Name  => $ParamItem->{Name},
                    Field => $LayoutObject->BuildSelection(
                        Data       => $ParamItem->{Data},
                        Name       => $ParamItem->{Name},
                        SelectedID => $LocalGetParam->( Param => $ParamItem->{Name} ) // $ParamItem->{SelectedID} || '',
                        Multiple => $ParamItem->{Multiple} || 0,
                        Size     => $ParamItem->{Size}     || '',
                        Class    => 'Modernize',
                    ),
                },
            );
        }
    }

    # get dynamic attributes
    elsif ( $Stat->{StatType} eq 'dynamic' ) {
        my %Name = (
            UseAsXvalue      => Translatable('X-axis'),
            UseAsValueSeries => Translatable('Y-axis'),
            UseAsRestriction => Translatable('Filter'),
        );

        for my $Use (qw(UseAsXvalue UseAsValueSeries UseAsRestriction)) {
            my $Flag = 0;
            $LayoutObject->Block(
                Name => 'Dynamic',
                Data => { Name => $Name{$Use} },
            );
            OBJECTATTRIBUTE:
            for my $ObjectAttribute ( @{ $Stat->{$Use} } ) {
                next OBJECTATTRIBUTE if !$ObjectAttribute->{Selected};

                my $ElementName = $Use . $ObjectAttribute->{Element};
                my %ValueHash;
                $Flag = 1;

                # Select All function
                if ( !$ObjectAttribute->{SelectedValues}[0] ) {
                    if (
                        $ObjectAttribute->{Values} && ref $ObjectAttribute->{Values} ne 'HASH'
                        )
                    {
                        $Kernel::OM->Get('Kernel::System::Log')->Log(
                            Priority => 'error',
                            Message  => 'Values needs to be a hash reference!'
                        );
                        next OBJECTATTRIBUTE;
                    }
                    my @Values = keys( %{ $ObjectAttribute->{Values} } );
                    $ObjectAttribute->{SelectedValues} = \@Values;
                }
                for ( @{ $ObjectAttribute->{SelectedValues} } ) {
                    if ( $ObjectAttribute->{Values} ) {
                        $ValueHash{$_} = $ObjectAttribute->{Values}->{$_};
                    }
                    else {
                        $ValueHash{Value} = $_;
                    }
                }

                $LayoutObject->Block(
                    Name => 'Element',
                    Data => { Name => $ObjectAttribute->{Name} },
                );

                # show fixed elements
                if ( $ObjectAttribute->{Fixed} ) {
                    if ( $ObjectAttribute->{Block} eq 'Time' ) {
                        if ( $Use eq 'UseAsRestriction' ) {
                            delete $ObjectAttribute->{SelectedValues};
                        }
                        my $TimeScale = $Self->_TimeScale();
                        if ( $ObjectAttribute->{TimeStart} ) {
                            $LayoutObject->Block(
                                Name => 'TimePeriodFixed',
                                Data => {
                                    TimeStart => $ObjectAttribute->{TimeStart},
                                    TimeStop  => $ObjectAttribute->{TimeStop},
                                },
                            );
                        }
                        elsif ( $ObjectAttribute->{TimeRelativeUnit} ) {
                            $LayoutObject->Block(
                                Name => 'TimeRelativeFixed',
                                Data => {
                                    TimeRelativeUnit  => $TimeScale->{ $ObjectAttribute->{TimeRelativeUnit} }->{Value},
                                    TimeRelativeCount => $ObjectAttribute->{TimeRelativeCount},
                                    TimeRelativeUpcomingCount => $ObjectAttribute->{TimeRelativeUpcomingCount},
                                },
                            );
                        }
                        if ( $ObjectAttribute->{SelectedValues}[0] ) {
                            $LayoutObject->Block(
                                Name => 'TimeScaleFixed',
                                Data => {
                                    Scale => $TimeScale->{ $ObjectAttribute->{SelectedValues}[0] }->{Value},
                                    Count => $ObjectAttribute->{TimeScaleCount},
                                },
                            );
                        }
                    }
                    else {

                        # find out which sort mechanism is used
                        my @Sorted;
                        if ( $ObjectAttribute->{SortIndividual} ) {
                            @Sorted = grep { $ValueHash{$_} } @{ $ObjectAttribute->{SortIndividual} };
                        }
                        else {
                            @Sorted = sort { $ValueHash{$a} cmp $ValueHash{$b} } keys %ValueHash;
                        }

                        my @FixedAttributes;

                        for (@Sorted) {
                            my $Value = $ValueHash{$_};
                            if ( $ObjectAttribute->{Translation} ) {
                                $Value = $LayoutObject->{LanguageObject}->Translate( $ValueHash{$_} );
                            }
                            push @FixedAttributes, $Value;
                        }

                        $LayoutObject->Block(
                            Name => 'Fixed',
                            Data => {
                                Value   => join( ', ', @FixedAttributes ),
                                Key     => $_,
                                Use     => $Use,
                                Element => $ObjectAttribute->{Element},
                            },
                        );
                    }
                }

                # show  unfixed elements
                else {
                    my %BlockData;
                    $BlockData{Name}    = $ObjectAttribute->{Name};
                    $BlockData{Element} = $ObjectAttribute->{Element};
                    $BlockData{Value}   = $ObjectAttribute->{SelectedValues}->[0];

                    my @SelectedIDs = $LocalGetArray->( Param => $ElementName );

                    if ( $ObjectAttribute->{Block} eq 'MultiSelectField' ) {
                        $BlockData{SelectField} = $LayoutObject->BuildSelection(
                            Data        => \%ValueHash,
                            Name        => $ElementName,
                            Multiple    => 1,
                            Size        => 5,
                            SelectedID  => @SelectedIDs ? [@SelectedIDs] : $ObjectAttribute->{SelectedValues},
                            Translation => $ObjectAttribute->{Translation},
                            TreeView => $ObjectAttribute->{TreeView} || 0,
                            Sort => scalar $ObjectAttribute->{Sort},
                            SortIndividual => scalar $ObjectAttribute->{SortIndividual},
                            Class          => 'Modernize',
                        );
                        $LayoutObject->Block(
                            Name => 'MultiSelectField',
                            Data => \%BlockData,
                        );
                    }
                    elsif ( $ObjectAttribute->{Block} eq 'SelectField' ) {

                        $BlockData{SelectField} = $LayoutObject->BuildSelection(
                            Data           => \%ValueHash,
                            Name           => $ElementName,
                            Translation    => $ObjectAttribute->{Translation},
                            TreeView       => $ObjectAttribute->{TreeView} || 0,
                            Sort           => scalar $ObjectAttribute->{Sort},
                            SortIndividual => scalar $ObjectAttribute->{SortIndividual},
                            SelectedID     => [ $LocalGetArray->( Param => $ElementName ) ],
                            Class          => 'Modernize',
                        );
                        $LayoutObject->Block(
                            Name => 'SelectField',
                            Data => \%BlockData,
                        );
                    }

                    elsif ( $ObjectAttribute->{Block} eq 'InputField' ) {
                        $LayoutObject->Block(
                            Name => 'InputField',
                            Data => {
                                Key   => $ElementName,
                                Value => $LocalGetParam->( Param => $ElementName )
                                    // $ObjectAttribute->{SelectedValues}[0],
                            },
                        );
                    }
                    elsif ( $ObjectAttribute->{Block} eq 'Time' ) {
                        $ObjectAttribute->{Element} = $Use . $ObjectAttribute->{Element};

                        my %Time;
                        if ( $ObjectAttribute->{TimeStart} ) {
                            if ( $LocalGetParam->( Param => $ElementName . 'StartYear' ) ) {
                                for my $Limit (qw(Start Stop)) {
                                    for my $Unit (qw(Year Month Day Hour Minute Second)) {
                                        if ( defined( $LocalGetParam->( Param => "$ElementName$Limit$Unit" ) ) ) {
                                            $Time{ $Limit . $Unit } = $LocalGetParam->(
                                                Param => $ElementName . "$Limit$Unit",
                                            );
                                        }
                                    }
                                    if ( !defined( $Time{ $Limit . 'Hour' } ) ) {
                                        if ( $Limit eq 'Start' ) {
                                            $Time{StartHour}   = 0;
                                            $Time{StartMinute} = 0;
                                            $Time{StartSecond} = 0;
                                        }
                                        elsif ( $Limit eq 'Stop' ) {
                                            $Time{StopHour}   = 23;
                                            $Time{StopMinute} = 59;
                                            $Time{StopSecond} = 59;
                                        }
                                    }
                                    elsif ( !defined( $Time{ $Limit . 'Second' } ) ) {
                                        if ( $Limit eq 'Start' ) {
                                            $Time{StartSecond} = 0;
                                        }
                                        elsif ( $Limit eq 'Stop' ) {
                                            $Time{StopSecond} = 59;
                                        }
                                    }
                                    $Time{"Time$Limit"} = sprintf(
                                        "%04d-%02d-%02d %02d:%02d:%02d",
                                        $Time{ $Limit . 'Year' },
                                        $Time{ $Limit . 'Month' },
                                        $Time{ $Limit . 'Day' },
                                        $Time{ $Limit . 'Hour' },
                                        $Time{ $Limit . 'Minute' },
                                        $Time{ $Limit . 'Second' },
                                    );
                                }
                            }
                        }
                        elsif ( $ObjectAttribute->{TimeRelativeUnit} ) {
                            $Time{TimeRelativeCount} = $LocalGetParam->(
                                Param => $ObjectAttribute->{Element} . 'TimeRelativeCount',
                            ) // $ObjectAttribute->{TimeRelativeCount};

                            $Time{TimeRelativeUpcomingCount} = $LocalGetParam->(
                                Param => $ObjectAttribute->{Element} . 'TimeRelativeUpcomingCount',
                            ) // $ObjectAttribute->{TimeRelativeUpcomingCount};

                            $Time{TimeScaleCount} = $LocalGetParam->(
                                Param => $ObjectAttribute->{Element} . 'TimeScaleCount',
                            ) || $ObjectAttribute->{TimeScaleCount};

                            $Time{TimeRelativeUnitLocalSelectedValue} = $LocalGetParam->(
                                Param => $ObjectAttribute->{Element} . 'TimeRelativeUnit'
                            );
                        }

                        if ( $Use ne 'UseAsRestriction' ) {
                            $Time{TimeScaleUnitLocalSelectedValue} = $LocalGetParam->(
                                Param => $ObjectAttribute->{Element},
                            );

                            # get the selected x axis time scale value for value series
                            if ( $Use eq 'UseAsValueSeries' ) {

                                # get the name for the x axis element
                                my $XAxisElementName = $ObjectAttribute->{Element};
                                $XAxisElementName =~ s{ \A UseAsValueSeries }{UseAsXvalue}xms;

                                # get the current x axis value
                                my $XAxisLocalSelectedValue = $LocalGetParam->(
                                    Param => $XAxisElementName,
                                );
                                $Time{SelectedXAxisValue} = $XAxisLocalSelectedValue
                                    || $Self->_GetSelectedXAxisTimeScaleValue( Stat => $Stat );

                                # save the x axis time scale element id for the output
                                $BlockData{XAxisTimeScaleElementID}
                                    = $XAxisElementName . '-' . $StatID . '-' . $Param{OutputCounter};
                            }
                        }

                        my %TimeData = $Self->_TimeOutput(
                            StatID        => $StatID,
                            OutputCounter => $Param{OutputCounter},
                            Output        => 'View',
                            Use           => $Use,
                            %{$ObjectAttribute},
                            %Time,
                        );
                        %BlockData = ( %BlockData, %TimeData );

                        if ( $ObjectAttribute->{TimeStart} ) {
                            $LayoutObject->Block(
                                Name => 'TimePeriod',
                                Data => \%BlockData,
                            );
                        }

                        elsif ( $ObjectAttribute->{TimeRelativeUnit} ) {
                            $LayoutObject->Block(
                                Name => 'TimePeriodRelative',
                                Data => \%BlockData,
                            );
                        }

                        # build the Timescale output
                        if ( $Use ne 'UseAsRestriction' ) {
                            $LayoutObject->Block(
                                Name => 'TimeScale',
                                Data => {
                                    %BlockData,
                                    Use => $Use,
                                },
                            );
                        }

                        # end of build timescale output
                    }
                }
            }

            # Show this Block if no value series or restrictions are selected
            if ( !$Flag ) {
                $LayoutObject->Block(
                    Name => 'NoElement',
                );
            }
        }
    }
    my %YesNo = (
        0 => 'No',
        1 => 'Yes'
    );
    my %ValidInvalid = (
        0 => 'invalid',
        1 => 'valid'
    );
    $Stat->{SumRowValue}                = $YesNo{ $Stat->{SumRow} };
    $Stat->{SumColValue}                = $YesNo{ $Stat->{SumCol} };
    $Stat->{CacheValue}                 = $YesNo{ $Stat->{Cache} };
    $Stat->{ShowAsDashboardWidgetValue} = $YesNo{ $Stat->{ShowAsDashboardWidget} // 0 };
    $Stat->{ValidValue}                 = $ValidInvalid{ $Stat->{Valid} };

    for my $Field (qw(CreatedBy ChangedBy)) {
        $Stat->{$Field} = $Kernel::OM->Get('Kernel::System::User')->UserName( UserID => $Stat->{$Field} );
    }

    $Output .= $LayoutObject->Output(
        TemplateFile => 'Statistics/StatsParamsWidget',
        Data         => {
            %{$Stat},
            AJAX => $Param{AJAX},
        },
        KeepScriptTags => $Param{AJAX},
    );
    return $Output;
}

sub GeneralSpecificationsWidget {
    my ( $Self, %Param ) = @_;

    my $LayoutObject = $Kernel::OM->Get('Kernel::Output::HTML::Layout');
    my $ParamObject  = $Kernel::OM->Get('Kernel::System::Web::Request');
    my $ConfigObject = $Kernel::OM->Get('Kernel::Config');

    # In case of page reload because of errors
    my %Errors   = %{ $Param{Errors}   // {} };
    my %GetParam = %{ $Param{GetParam} // {} };

    my $Stat;
    if ( $Param{StatID} ) {
        $Stat = $Kernel::OM->Get('Kernel::System::Stats')->StatsGet(
            StatID => $Param{StatID},
            UserID => $Param{UserID},
        );
    }
    else {
        $Stat->{StatID}     = '';
        $Stat->{StatNumber} = '';
        $Stat->{Valid}      = 1;
    }

    my %Frontend;

    # create selectboxes 'Cache', 'SumRow', 'SumCol', and 'Valid'
    for my $Key (qw(Cache ShowAsDashboardWidget SumRow SumCol)) {
        $Frontend{ 'Select' . $Key } = $LayoutObject->BuildSelection(
            Data => {
                0 => 'No',
                1 => 'Yes'
            },
            SelectedID => $GetParam{$Key} // $Stat->{$Key} || 0,
            Name       => $Key,
            Class      => 'Modernize',
        );
    }

    # New statistics don't get this select.
    if ( !$Stat->{ObjectBehaviours}->{ProvidesDashboardWidget} ) {
        $Frontend{'SelectShowAsDashboardWidget'} = $LayoutObject->BuildSelection(
            Data => {
                0 => 'No (not supported)',
            },
            SelectedID => 0,
            Name       => 'ShowAsDashboardWidget',
            Class      => 'Modernize',
        );
    }

    $Frontend{SelectValid} = $LayoutObject->BuildSelection(
        Data => {
            0 => 'invalid',
            1 => 'valid',
        },
        SelectedID => $GetParam{Valid} // $Stat->{Valid},
        Name       => 'Valid',
        Class      => 'Modernize',
    );

    # get the default selected formats
    my $DefaultSelectedFormat = $ConfigObject->Get('Stats::DefaultSelectedFormat') || [];

    # Create a new statistic
    if ( !$Stat->{StatType} ) {
        my $DynamicFiles = $Kernel::OM->Get('Kernel::System::Stats')->GetDynamicFiles();

        my %ObjectModules;
        DYNAMIC_FILE:
        for my $DynamicFile ( sort keys %{ $DynamicFiles // {} } ) {
            my $ObjectName = 'Kernel::System::Stats::Dynamic::' . $DynamicFile;

            next DYNAMIC_FILE if !$Kernel::OM->Get('Kernel::System::Main')->Require($ObjectName);
            my $Object = $ObjectName->new();
            next DYNAMIC_FILE if !$Object;
            if ( $Object->can('GetStatElement') ) {
                $ObjectModules{DynamicMatrix}->{$ObjectName} = $DynamicFiles->{$DynamicFile};
            }
            else {
                $ObjectModules{DynamicList}->{$ObjectName} = $DynamicFiles->{$DynamicFile};
            }
        }

        my $StaticFiles = $Kernel::OM->Get('Kernel::System::Stats')->GetStaticFiles(
            OnlyUnusedFiles => 1,
            UserID          => $Param{UserID},
        );
        for my $StaticFile ( sort keys %{ $StaticFiles // {} } ) {
            $ObjectModules{Static}->{ 'Kernel::System::Stats::Static::' . $StaticFile } = $StaticFiles->{$StaticFile};
        }

        $Frontend{StatisticPreselection} = $ParamObject->GetParam( Param => 'StatisticPreselection' );

        if ( $Frontend{StatisticPreselection} eq 'Static' ) {
            $Frontend{StatType}         = 'static';
            $Frontend{SelectObjectType} = $LayoutObject->BuildSelection(
                Data  => $ObjectModules{Static},
                Name  => 'ObjectModule',
                Class => 'Modernize Validate_Required' . ( $Errors{ObjectModuleServerError} ? ' ServerError' : '' ),
                Translation => 0,
                SelectedID  => $GetParam{ObjectModule},
            );
        }
        elsif ( $Frontend{StatisticPreselection} eq 'DynamicList' ) {

            # remove the default selected graph formats for the dynamic lists
            @{$DefaultSelectedFormat} = grep { $_ !~ m{^D3} } @{$DefaultSelectedFormat};

            $Frontend{StatType}         = 'dynamic';
            $Frontend{SelectObjectType} = $LayoutObject->BuildSelection(
                Data        => $ObjectModules{DynamicList},
                Name        => 'ObjectModule',
                Translation => 1,
                Class       => 'Modernize ' . ( $Errors{ObjectModuleServerError} ? ' ServerError' : '' ),
                SelectedID => $GetParam{ObjectModule} // $ConfigObject->Get('Stats::DefaultSelectedDynamicObject'),
            );
        }

        # DynamicMatrix
        else {
            $Frontend{StatType}         = 'dynamic';
            $Frontend{SelectObjectType} = $LayoutObject->BuildSelection(
                Data        => $ObjectModules{DynamicMatrix},
                Name        => 'ObjectModule',
                Translation => 1,
                Class       => 'Modernize ' . ( $Errors{ObjectModuleServerError} ? ' ServerError' : '' ),
                SelectedID => $GetParam{ObjectModule} // $ConfigObject->Get('Stats::DefaultSelectedDynamicObject'),
            );

        }
    }

    # get the avaible formats
    my $AvailableFormats = $ConfigObject->Get('Stats::Format');

    # create multiselectboxes 'format'
    $Stat->{SelectFormat} = $LayoutObject->BuildSelection(
        Data     => $AvailableFormats,
        Name     => 'Format',
        Class    => 'Modernize Validate_Required' . ( $Errors{FormatServerError} ? ' ServerError' : '' ),
        Multiple => 1,
        Size     => 5,
        SelectedID => $GetParam{Format} // $Stat->{Format} || $DefaultSelectedFormat,
    );

    # create multiselectboxes 'permission'
    my %Permission = (
        Data => { $Kernel::OM->Get('Kernel::System::Group')->GroupList( Valid => 1 ) },
        Name => 'Permission',
        Class => 'Modernize Validate_Required' . ( $Errors{PermissionServerError} ? ' ServerError' : '' ),
        Multiple    => 1,
        Size        => 5,
        Translation => 0,
    );
    if ( $GetParam{Permission} // $Stat->{Permission} ) {
        $Permission{SelectedID} = $GetParam{Permission} // $Stat->{Permission};
    }
    else {
        $Permission{SelectedValue} = $ConfigObject->Get('Stats::DefaultSelectedPermissions');
    }
    $Stat->{SelectPermission} = $LayoutObject->BuildSelection(%Permission);

    # provide the timezone field only if the system use UTC as system time, the TimeZoneUser is active
    # and for dynamic statistics
    if (
        !$Kernel::OM->Get('Kernel::System::Time')->ServerLocalTimeOffsetSeconds()
        && $ConfigObject->Get('TimeZoneUser')
        && (
            ( $Stat->{StatType} && $Stat->{StatType} eq 'dynamic' )
            || ( $Frontend{StatType} && $Frontend{StatType} eq 'dynamic' )
        )
        )
    {

        my %TimeZoneBuildSelection = $Self->_TimeZoneBuildSelection();

        $Stat->{SelectTimeZone} = $LayoutObject->BuildSelection(
            %TimeZoneBuildSelection,
            Name       => 'TimeZone',
            Class      => 'Modernize ' . ( $Errors{TimeZoneServerError} ? ' ServerError' : '' ),
            SelectedID => $GetParam{TimeZone} // $Stat->{TimeZone} // $ConfigObject->Get('TimeZone') || 0,
        );
    }

    my $Output .= $LayoutObject->Output(
        TemplateFile => 'Statistics/GeneralSpecificationsWidget',
        Data         => {
            %Frontend,
            %{$Stat},
            %GetParam,
            %Errors,
        },
    );
    return $Output;
}

sub XAxisWidget {
    my ( $Self, %Param ) = @_;

    my $Stat = $Param{Stat};

    my $LayoutObject = $Kernel::OM->Get('Kernel::Output::HTML::Layout');

    #my $ParamObject  = $Kernel::OM->Get('Kernel::System::Web::Request');
    my $ConfigObject = $Kernel::OM->Get('Kernel::Config');

    # if only one value is available select this value
    if ( !$Stat->{UseAsXvalue}[0]{Selected} && scalar( @{ $Stat->{UseAsXvalue} } ) == 1 ) {
        $Stat->{UseAsXvalue}[0]{Selected} = 1;
        $Stat->{UseAsXvalue}[0]{Fixed}    = 1;
    }

    for my $ObjectAttribute ( @{ $Stat->{UseAsXvalue} } ) {
        my %BlockData;
        $BlockData{Fixed}   = 'checked="checked"';
        $BlockData{Checked} = '';
        $BlockData{Block}   = $ObjectAttribute->{Block};

        # things which should be done if this attribute is selected
        if ( $ObjectAttribute->{Selected} ) {
            $BlockData{Checked} = 'checked="checked"';
            if ( !$ObjectAttribute->{Fixed} ) {
                $BlockData{Fixed} = '';
            }
        }

        if ( $ObjectAttribute->{Block} eq 'SelectField' || $ObjectAttribute->{Block} eq 'MultiSelectField' ) {
            my $DFTreeClass = ( $ObjectAttribute->{ShowAsTree} && $ObjectAttribute->{IsDynamicField} )
                ? 'DynamicFieldWithTreeView' : '';
            $BlockData{SelectField} = $LayoutObject->BuildSelection(
                Data           => $ObjectAttribute->{Values},
                Name           => 'XAxis' . $ObjectAttribute->{Element},
                Multiple       => 1,
                Size           => 5,
                Class          => "Modernize $DFTreeClass",
                SelectedID     => $ObjectAttribute->{SelectedValues},
                Translation    => $ObjectAttribute->{Translation},
                TreeView       => $ObjectAttribute->{TreeView} || 0,
                Sort           => scalar $ObjectAttribute->{Sort},
                SortIndividual => scalar $ObjectAttribute->{SortIndividual},
            );

            if ( $ObjectAttribute->{ShowAsTree} && $ObjectAttribute->{IsDynamicField} ) {
                my $TreeSelectionMessage = $LayoutObject->{LanguageObject}->Translate("Show Tree Selection");
                $BlockData{SelectField}
                    .= ' <a href="#" title="'
                    . $TreeSelectionMessage
                    . '" class="ShowTreeSelection"><span>'
                    . $TreeSelectionMessage . '</span><i class="fa fa-sitemap"></i></a>';
            }
        }

        $BlockData{Name}    = $ObjectAttribute->{Name};
        $BlockData{Element} = 'XAxis' . $ObjectAttribute->{Element};

        # show the attribute block
        $LayoutObject->Block(
            Name => 'Attribute',
            Data => \%BlockData,
        );

        if ( $ObjectAttribute->{Block} eq 'Time' ) {

            my %TimeData = $Self->_TimeOutput(
                Output => 'Edit',
                Use    => 'UseAsXvalue',
                %{$ObjectAttribute},
                Element => $BlockData{Element},
            );
            %BlockData = ( %BlockData, %TimeData );
        }

        my $Block = $ObjectAttribute->{Block};

        if ( $Block eq 'SelectField' ) {
            $Block = 'MultiSelectField';
        }

        # show the input element
        $LayoutObject->Block(
            Name => $Block,
            Data => \%BlockData,
        );
    }

    my $Output .= $LayoutObject->Output(
        TemplateFile => 'Statistics/XAxisWidget',
        Data         => {
            %{$Stat},
        },
    );
    return $Output;
}

sub YAxisWidget {
    my ( $Self, %Param ) = @_;

    my $Stat = $Param{Stat};

    my $LayoutObject = $Kernel::OM->Get('Kernel::Output::HTML::Layout');

    #my $ParamObject  = $Kernel::OM->Get('Kernel::System::Web::Request');
    my $ConfigObject = $Kernel::OM->Get('Kernel::Config');

    OBJECTATTRIBUTE:
    for my $ObjectAttribute ( @{ $Stat->{UseAsValueSeries} } ) {
        my %BlockData;
        $BlockData{Fixed}   = 'checked="checked"';
        $BlockData{Checked} = '';
        $BlockData{Block}   = $ObjectAttribute->{Block};

        if ( $ObjectAttribute->{Selected} ) {
            $BlockData{Checked} = 'checked="checked"';
            if ( !$ObjectAttribute->{Fixed} ) {
                $BlockData{Fixed} = '';
            }
        }

        if ( $ObjectAttribute->{Block} eq 'SelectField' || $ObjectAttribute->{Block} eq 'MultiSelectField' ) {
            my $DFTreeClass = ( $ObjectAttribute->{ShowAsTree} && $ObjectAttribute->{IsDynamicField} )
                ? 'DynamicFieldWithTreeView' : '';
            $BlockData{SelectField} = $LayoutObject->BuildSelection(
                Data           => $ObjectAttribute->{Values},
                Name           => 'YAxis' . $ObjectAttribute->{Element},
                Multiple       => 1,
                Size           => 5,
                Class          => "Modernize $DFTreeClass",
                SelectedID     => $ObjectAttribute->{SelectedValues},
                Translation    => $ObjectAttribute->{Translation},
                TreeView       => $ObjectAttribute->{TreeView} || 0,
                Sort           => scalar $ObjectAttribute->{Sort},
                SortIndividual => scalar $ObjectAttribute->{SortIndividual},
            );

            if ( $ObjectAttribute->{ShowAsTree} && $ObjectAttribute->{IsDynamicField} ) {
                my $TreeSelectionMessage = $LayoutObject->{LanguageObject}->Translate("Show Tree Selection");
                $BlockData{SelectField}
                    .= ' <a href="#" title="'
                    . $TreeSelectionMessage
                    . '" class="ShowTreeSelection"><span>'
                    . $TreeSelectionMessage . '</span><i class="fa fa-sitemap"></i></a>';
            }
        }

        $BlockData{Name}    = $ObjectAttribute->{Name};
        $BlockData{Element} = 'YAxis' . $ObjectAttribute->{Element};

        # show the attribute block
        $LayoutObject->Block(
            Name => 'Attribute',
            Data => \%BlockData,
        );

        if ( $ObjectAttribute->{Block} eq 'Time' ) {

            # get the selected x axis time scale value
            my $SelectedXAxisTimeScaleValue = $Self->_GetSelectedXAxisTimeScaleValue( Stat => $Stat );

            my %TimeData = $Self->_TimeOutput(
                Output => 'Edit',
                Use    => 'UseAsValueSeries',
                %{$ObjectAttribute},
                Element            => $BlockData{Element},
                SelectedXAxisValue => $SelectedXAxisTimeScaleValue,
            );
            %BlockData = ( %BlockData, %TimeData );
        }

        my $Block = $ObjectAttribute->{Block};

        if ( $Block eq 'SelectField' ) {
            $Block = 'MultiSelectField';
        }

        # show the input element
        $LayoutObject->Block(
            Name => $Block,
            Data => \%BlockData,
        );
    }

    my $Output .= $LayoutObject->Output(
        TemplateFile => 'Statistics/YAxisWidget',
        Data         => {
            %{$Stat},
        },
    );
    return $Output;
}

sub RestrictionsWidget {
    my ( $Self, %Param ) = @_;

    my $Stat = $Param{Stat};

    my $LayoutObject = $Kernel::OM->Get('Kernel::Output::HTML::Layout');

    #my $ParamObject  = $Kernel::OM->Get('Kernel::System::Web::Request');
    my $ConfigObject = $Kernel::OM->Get('Kernel::Config');

    for my $ObjectAttribute ( @{ $Stat->{UseAsRestriction} } ) {
        my %BlockData;
        $BlockData{Fixed}   = 'checked="checked"';
        $BlockData{Checked} = '';
        $BlockData{Block}   = $ObjectAttribute->{Block};

        if ( $ObjectAttribute->{Selected} ) {
            $BlockData{Checked} = 'checked="checked"';
            if ( !$ObjectAttribute->{Fixed} ) {
                $BlockData{Fixed} = "";
            }
        }

        if ( $ObjectAttribute->{SelectedValues} ) {
            $BlockData{SelectedValue} = $ObjectAttribute->{SelectedValues}[0];
        }
        else {
            $BlockData{SelectedValue} = '';
            $ObjectAttribute->{SelectedValues} = undef;
        }

        if (
            $ObjectAttribute->{Block} eq 'MultiSelectField'
            || $ObjectAttribute->{Block} eq 'SelectField'
            )
        {
            my $DFTreeClass = ( $ObjectAttribute->{ShowAsTree} && $ObjectAttribute->{IsDynamicField} )
                ? 'DynamicFieldWithTreeView' : '';

            $BlockData{SelectField} = $LayoutObject->BuildSelection(
                Data           => $ObjectAttribute->{Values},
                Name           => 'Restrictions' . $ObjectAttribute->{Element},
                Multiple       => 1,
                Size           => 5,
                Class          => "Modernize $DFTreeClass",
                SelectedID     => $ObjectAttribute->{SelectedValues},
                Translation    => $ObjectAttribute->{Translation},
                TreeView       => $ObjectAttribute->{TreeView} || 0,
                Sort           => scalar $ObjectAttribute->{Sort},
                SortIndividual => scalar $ObjectAttribute->{SortIndividual},
            );

            if ( $ObjectAttribute->{ShowAsTree} && $ObjectAttribute->{IsDynamicField} ) {
                my $TreeSelectionMessage = $LayoutObject->{LanguageObject}->Translate("Show Tree Selection");
                $BlockData{SelectField}
                    .= ' <a href="#" title="'
                    . $TreeSelectionMessage
                    . '" class="ShowTreeSelection"><span>'
                    . $TreeSelectionMessage . '</span><i class="fa fa-sitemap"></i></a>';
            }
        }

        $BlockData{Element} = 'Restrictions' . $ObjectAttribute->{Element};
        $BlockData{Name}    = $ObjectAttribute->{Name};

        # show the attribute block
        $LayoutObject->Block(
            Name => 'Attribute',
            Data => \%BlockData,
        );
        if ( $ObjectAttribute->{Block} eq 'Time' ) {

            my %TimeData = $Self->_TimeOutput(
                Output => 'Edit',
                Use    => 'UseAsRestriction',
                %{$ObjectAttribute},
                Element => $BlockData{Element},
            );
            %BlockData = ( %BlockData, %TimeData );
        }

        # show the input element
        $LayoutObject->Block(
            Name => $ObjectAttribute->{Block},
            Data => \%BlockData,
        );
    }

    my $Output .= $LayoutObject->Output(
        TemplateFile => 'Statistics/RestrictionsWidget',
        Data         => {
            %{$Stat},
        },
    );
    return $Output;
}

sub PreviewWidget {
    my ( $Self, %Param ) = @_;

    my $Stat = $Param{Stat};

    my $LayoutObject = $Kernel::OM->Get('Kernel::Output::HTML::Layout');

    my %StatsConfigurationErrors;

    $Self->StatsConfigurationValidate(
        Stat   => $Stat,
        Errors => \%StatsConfigurationErrors,
    );

    my %Frontend;

    if ( !%StatsConfigurationErrors ) {
        $Frontend{PreviewResult} = $Kernel::OM->Get('Kernel::System::Stats')->StatsRun(
            StatID   => $Stat->{StatID},
            GetParam => $Stat,
            Preview  => 1,
            UserID   => $Param{UserID},
        );
    }

    my $Output .= $LayoutObject->Output(
        TemplateFile => 'Statistics/PreviewWidget',
        Data         => {
            %{$Stat},
            %Frontend,
            StatsConfigurationErrors => \%StatsConfigurationErrors,
        },
    );
    return $Output;
}

sub StatsParamsGet {
    my ( $Self, %Param ) = @_;

    my $Stat = $Param{Stat};

    my $HasUserGetParam = ref $Param{UserGetParam} eq 'HASH';

    my %UserGetParam = %{ $Param{UserGetParam} // {} };

    my $ConfigObject = $Kernel::OM->Get('Kernel::Config');
    my $ParamObject  = $Kernel::OM->Get('Kernel::System::Web::Request');
    my $TimeObject   = $Kernel::OM->Get('Kernel::System::Time');

    my $LocalGetParam = sub {
        my (%Param) = @_;
        my $Param = $Param{Param};
        return $HasUserGetParam ? $UserGetParam{$Param} : $ParamObject->GetParam( Param => $Param );
    };

    my $LocalGetArray = sub {
        my (%Param) = @_;
        my $Param = $Param{Param};
        if ($HasUserGetParam) {
            if ( $UserGetParam{$Param} && ref $UserGetParam{$Param} eq 'ARRAY' ) {
                return @{ $UserGetParam{$Param} };
            }
            return;
        }
        return $ParamObject->GetArray( Param => $Param );
    };

    my ( %GetParam, @Errors );

    # get the time zone param
    if (
        !$TimeObject->ServerLocalTimeOffsetSeconds()
        && $ConfigObject->Get('TimeZoneUser')
        && length $LocalGetParam->( Param => 'TimeZone' )
        )
    {
        $GetParam{TimeZone} = $LocalGetParam->( Param => 'TimeZone' ) // $Stat->{TimeZone};
    }

    #
    # Static statistics
    #
    if ( $Stat->{StatType} eq 'static' ) {
        my ( $s, $m, $h, $D, $M, $Y ) = $TimeObject->SystemTime2Date(
            SystemTime => $TimeObject->SystemTime(),
        );
        $GetParam{Year}  = $Y;
        $GetParam{Month} = $M;
        $GetParam{Day}   = $D;

        my $Params = $Kernel::OM->Get('Kernel::System::Stats')->GetParams(
            StatID => $Stat->{StatID},
        );

        PARAMITEM:
        for my $ParamItem ( @{$Params} ) {
            if ( $ParamItem->{Multiple} ) {
                $GetParam{ $ParamItem->{Name} } = [ $LocalGetArray->( Param => $ParamItem->{Name} ) ];
                next PARAMITEM;
            }
            $GetParam{ $ParamItem->{Name} } = $LocalGetParam->( Param => $ParamItem->{Name} );
        }
    }
    #
    # Dynamic statistics
    #
    else {

        my $TimePeriod         = 0;
        my $TimeUpcomingPeriod = 0;

        for my $Use (qw(UseAsXvalue UseAsValueSeries UseAsRestriction)) {
            $Stat->{$Use} ||= [];

            my @Array   = @{ $Stat->{$Use} };
            my $Counter = 0;
            ELEMENT:
            for my $Element (@Array) {
                next ELEMENT if !$Element->{Selected};

                my $ElementName = $Use . $Element->{'Element'};

                if ( !$Element->{Fixed} ) {

                    if ( $LocalGetArray->( Param => $ElementName ) ) {
                        my @SelectedValues = $LocalGetArray->(
                            Param => $ElementName
                        );

                        $Element->{SelectedValues} = \@SelectedValues;
                    }
                    elsif ( $LocalGetParam->( Param => $ElementName ) ) {
                        my $SelectedValue = $LocalGetParam->(
                            Param => $ElementName
                        );

                        $Element->{SelectedValues} = [$SelectedValue];
                    }

                    # set the first value for a single select field, if no selected value is given
                    if (
                        $Element->{Block} eq 'SelectField'
                        && (
                            !IsArrayRefWithData( $Element->{SelectedValues} )
                            || scalar @{ $Element->{SelectedValues} } > 1
                        )
                        )
                    {

                        my @Values = sort keys %{ $Element->{Values} };

                        if (
                            IsArrayRefWithData( $Element->{SelectedValues} )
                            && scalar @{ $Element->{SelectedValues} } > 1
                            )
                        {
                            @Values = @{ $Element->{SelectedValues} };
                        }

                        $Element->{SelectedValues} = [ $Values[0] ];
                    }

                    if ( $Element->{Block} eq 'InputField' ) {

                        # Show warning if restrictions contain stop words within ticket search.
                        my %StopWordFields = $Self->_StopWordFieldsGet();

                        if ( $StopWordFields{ $Element->{Element} } ) {
                            my $ErrorMessage = $Self->_StopWordErrorCheck(
                                $Element->{Element} => $Element->{SelectedValues}[0],
                            );
                            if ($ErrorMessage) {
                                push @Errors, "$Element->{Name}: $ErrorMessage";
                            }
                        }

                    }
                    if ( $Element->{Block} eq 'Time' ) {
                        my %Time;

                        # Check if it is an absolute time period
                        if ( $Element->{TimeStart} ) {

                            # get time object
                            my $TimeObject = $Kernel::OM->Get('Kernel::System::Time');

                            if ( $LocalGetParam->( Param => $ElementName . 'StartYear' ) ) {
                                for my $Limit (qw(Start Stop)) {
                                    for my $Unit (qw(Year Month Day Hour Minute Second)) {
                                        if ( defined( $LocalGetParam->( Param => "$ElementName$Limit$Unit" ) ) ) {
                                            $Time{ $Limit . $Unit } = $LocalGetParam->(
                                                Param => $ElementName . "$Limit$Unit",
                                            );
                                        }
                                    }
                                    if ( !defined( $Time{ $Limit . 'Hour' } ) ) {
                                        if ( $Limit eq 'Start' ) {
                                            $Time{StartHour}   = 0;
                                            $Time{StartMinute} = 0;
                                            $Time{StartSecond} = 0;
                                        }
                                        elsif ( $Limit eq 'Stop' ) {
                                            $Time{StopHour}   = 23;
                                            $Time{StopMinute} = 59;
                                            $Time{StopSecond} = 59;
                                        }
                                    }
                                    elsif ( !defined( $Time{ $Limit . 'Second' } ) ) {
                                        if ( $Limit eq 'Start' ) {
                                            $Time{StartSecond} = 0;
                                        }
                                        elsif ( $Limit eq 'Stop' ) {
                                            $Time{StopSecond} = 59;
                                        }
                                    }
                                    $Time{"Time$Limit"} = sprintf(
                                        "%04d-%02d-%02d %02d:%02d:%02d",
                                        $Time{ $Limit . 'Year' },
                                        $Time{ $Limit . 'Month' },
                                        $Time{ $Limit . 'Day' },
                                        $Time{ $Limit . 'Hour' },
                                        $Time{ $Limit . 'Minute' },
                                        $Time{ $Limit . 'Second' },
                                    );
                                }

                                $Element->{TimeStart} = $Time{TimeStart};
                                $Element->{TimeStop}  = $Time{TimeStop};

                                if ( $Use eq 'UseAsXvalue' ) {
                                    $TimePeriod
                                        = ( $TimeObject->TimeStamp2SystemTime( String => $Element->{TimeStop} ) )
                                        - ( $TimeObject->TimeStamp2SystemTime( String => $Element->{TimeStart} ) );
                                }
                            }
                        }
                        else {

                            if ( $Use ne 'UseAsValueSeries' ) {
                                $Time{TimeRelativeUnit}
                                    = $LocalGetParam->( Param => $ElementName . 'TimeRelativeUnit' );
                                $Time{TimeRelativeCount}
                                    = $LocalGetParam->( Param => $ElementName . 'TimeRelativeCount' );
                                $Time{TimeRelativeUpcomingCount}
                                    = $LocalGetParam->( Param => $ElementName . 'TimeRelativeUpcomingCount' );

                                # Use Values of the stat as fallback
                                $Time{TimeRelativeCount}         //= $Element->{TimeRelativeCount};
                                $Time{TimeRelativeUpcomingCount} //= $Element->{TimeRelativeUpcomingCount};
                                $Time{TimeRelativeUnit} ||= $Element->{TimeRelativeUnit};

                                if ( !$Time{TimeRelativeCount} && !$Time{TimeRelativeUpcomingCount} ) {
                                    push @Errors,
                                        Translatable(
                                        'No past complete or the current+upcoming complete relative time value selected.'
                                        );
                                }

                                if ( $Use eq 'UseAsXvalue' ) {
                                    $TimePeriod = $Time{TimeRelativeCount} * $Self->_TimeInSeconds(
                                        TimeUnit => $Time{TimeRelativeUnit},
                                    );
                                    $TimeUpcomingPeriod = $Time{TimeRelativeUpcomingCount} * $Self->_TimeInSeconds(
                                        TimeUnit => $Time{TimeRelativeUnit},
                                    );
                                }

                                $Element->{TimeRelativeCount}         = $Time{TimeRelativeCount};
                                $Element->{TimeRelativeUpcomingCount} = $Time{TimeRelativeUpcomingCount};
                                $Element->{TimeRelativeUnit}          = $Time{TimeRelativeUnit};
                            }
                        }

                        if ( $Use ne 'UseAsRestriction' ) {

                            if ( $LocalGetParam->( Param => $ElementName ) ) {
                                $Element->{SelectedValues} = [ $LocalGetParam->( Param => $ElementName ) ];
                            }

                            if ( $LocalGetParam->( Param => $ElementName . 'TimeScaleCount' ) ) {

                                $Time{TimeScaleCount} = $LocalGetParam->( Param => $ElementName . 'TimeScaleCount' );

                                # Use Values of the stat as fallback
                                $Time{TimeScaleCount} ||= $Element->{TimeScaleCount};

                                $Element->{TimeScaleCount} = $Time{TimeScaleCount};
                            }
                        }
                    }
                }

                $GetParam{$Use}->[$Counter] = $Element;
                $Counter++;

            }
            if ( ref $GetParam{$Use} ne 'ARRAY' ) {
                $GetParam{$Use} = [];
            }
        }

        # check if the timeperiod is too big or the time scale too small
        if (
            $GetParam{UseAsXvalue}[0]{Block} eq 'Time'
            && (
                !$GetParam{UseAsValueSeries}[0]
                || (
                    $GetParam{UseAsValueSeries}[0]
                    && $GetParam{UseAsValueSeries}[0]{Block} ne 'Time'
                )
            )
            )
        {

            my $ScalePeriod = $Self->_TimeInSeconds(
                TimeUnit => $GetParam{UseAsXvalue}[0]{SelectedValues}[0]
            );

            # integrate this functionality in the completenesscheck
            my $MaxAttr = $ConfigObject->Get('Stats::MaxXaxisAttributes') || 1000;
            if (
                ( $TimePeriod + $TimeUpcomingPeriod ) / ( $ScalePeriod * $GetParam{UseAsXvalue}[0]{TimeScaleCount} )
                > $MaxAttr
                )
            {
                push @Errors, Translatable('The selected time period is larger than the allowed time period.');
            }
        }

        if ( $GetParam{UseAsValueSeries}[0]{Block} && $GetParam{UseAsValueSeries}[0]{Block} eq 'Time' ) {

            my $TimeScale = $Self->_TimeScale(
                SelectedXAxisValue => $GetParam{UseAsXvalue}[0]{SelectedValues}[0],
            );

            if ( !IsHashRefWithData($TimeScale) ) {
                push @Errors,
                    Translatable(
                    'No time scale value available for the current selected time scale value on the X axis.'
                    );
            }
        }
    }

    if (@Errors) {
        die \@Errors;
    }

    return %GetParam;
}

sub StatsResultRender {
    my ( $Self, %Param ) = @_;

    my @StatArray = @{ $Param{StatArray} // [] };
    my $Stat = $Param{Stat};

    my $LayoutObject = $Kernel::OM->Get('Kernel::Output::HTML::Layout');
    my $ConfigObject = $Kernel::OM->Get('Kernel::Config');

    my $TitleArrayRef = shift @StatArray;
    my $Title         = $TitleArrayRef->[0];
    my $HeadArrayRef  = shift @StatArray;

    # if array = empty
    if ( !@StatArray ) {
        push @StatArray, [ ' ', 0 ];
    }

    # Generate Filename
    my $Filename = $Kernel::OM->Get('Kernel::System::Stats')->StringAndTimestamp2Filename(
        String   => $Stat->{Title} . ' Created',
        TimeZone => $Param{TimeZone},
    );

    # Translate the column and row description
    $Self->_ColumnAndRowTranslation(
        StatArrayRef => \@StatArray,
        HeadArrayRef => $HeadArrayRef,
        StatRef      => $Stat,
        ExchangeAxis => $Param{ExchangeAxis},
    );

    # get CSV object
    my $CSVObject = $Kernel::OM->Get('Kernel::System::CSV');

    # generate D3 output
    if ( $Param{Format} =~ m{^D3} ) {
        my $Output = $LayoutObject->Header(
            Value => $Title,
            Type  => 'Small',
        );
        $Output .= $LayoutObject->Output(
            Data => {
                %{$Stat},
                RawData => [
                    [$Title],
                    $HeadArrayRef,
                    @StatArray,
                ],
                %Param,
            },
            TemplateFile => 'Statistics/StatsResultRender/D3',
        );
        $Output .= $LayoutObject->Footer(
            Type => 'Small',
        );
        return $Output;
    }

    # generate csv output
    if ( $Param{Format} eq 'CSV' ) {

        # get Separator from language file
        my $UserCSVSeparator = $LayoutObject->{LanguageObject}->{Separator};

        if ( $ConfigObject->Get('PreferencesGroups')->{CSVSeparator}->{Active} ) {
            my %UserData = $$Kernel::OM->Get('Kernel::System::User')->GetUserData(
                UserID => $Param{UserID}
            );
            $UserCSVSeparator = $UserData{UserCSVSeparator} if $UserData{UserCSVSeparator};
        }
        my $Output .= $CSVObject->Array2CSV(
            Head      => $HeadArrayRef,
            Data      => \@StatArray,
            Separator => $UserCSVSeparator,
        );

        return $LayoutObject->Attachment(
            Filename    => $Filename . '.csv',
            ContentType => "text/csv",
            Content     => $Output,
        );
    }

    # generate excel output
    elsif ( $Param{Format} eq 'Excel' ) {
        my $Output .= $CSVObject->Array2CSV(
            Head   => $HeadArrayRef,
            Data   => \@StatArray,
            Format => 'Excel',
        );

        return $LayoutObject->Attachment(
            Filename    => $Filename . '.xlsx',
            ContentType => "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
            Content     => $Output,
        );

    }

    # pdf or html output
    elsif ( $Param{Format} eq 'Print' ) {
        my $PDFString = $Kernel::OM->Get('Kernel::Output::PDF::Statistics')->GeneratePDF(
            Stat         => $Stat,
            Title        => $Title,
            HeadArrayRef => $HeadArrayRef,
            StatArray    => \@StatArray,
            TimeZone     => $Param{TimeZone},
            UserID       => $Param{UserID},
        );
        return $LayoutObject->Attachment(
            Filename    => $Filename . '.pdf',
            ContentType => 'application/pdf',
            Content     => $PDFString,
            Type        => 'inline',
        );
    }
}

=item StatsConfigurationValidate()

    my $StatCorrectlyConfigured = $StatsViewObject->StatsConfigurationValidate(
        StatData => \%StatData,
        Errors   => \%Errors,   # Hash to be populated with errors, if any
    );

=cut

sub StatsConfigurationValidate {
    my ( $Self, %Param ) = @_;

    for my $Needed (qw(Stat Errors)) {
        if ( !$Param{$Needed} ) {
            $Kernel::OM->Get('Kernel::System::Log')->Log(
                Priority => 'error',
                Message  => "Need $Needed"
            );
            return;
        }
    }

    my %GeneralSpecificationFieldErrors;
    my ( %XAxisFieldErrors, @XAxisGeneralErrors );
    my ( %YAxisFieldErrors, @YAxisGeneralErrors );
    my (%RestrictionsFieldErrors);

    my %Stat = %{ $Param{Stat} };

    # Specification
    {
        KEY:
        for my $Field (qw(Title Description StatType Permission Format ObjectModule)) {
            if ( !$Stat{$Field} ) {
                $GeneralSpecificationFieldErrors{$Field} = Translatable('This field is required.');
            }
        }
        if ( $Stat{StatType} && $Stat{StatType} eq 'static' && !$Stat{File} ) {
            $GeneralSpecificationFieldErrors{File} = Translatable('This field is required.');
        }
        if ( $Stat{StatType} && $Stat{StatType} eq 'dynamic' && !$Stat{Object} ) {
            $GeneralSpecificationFieldErrors{Object} = Translatable('This field is required.');
        }
    }

    my $ConfigObject = $Kernel::OM->Get('Kernel::Config');
    my $TimeObject   = $Kernel::OM->Get('Kernel::System::Time');

    if ( $Stat{StatType} eq 'dynamic' ) {

        # save the selected x axis time scale value for some checks for the y axis
        my $SelectedXAxisTimeScaleValue;

        # X Axis
        {
            my $Flag = 0;
            XVALUE:
            for my $Xvalue ( @{ $Stat{UseAsXvalue} } ) {
                next XVALUE if !$Xvalue->{Selected};

                if ( $Xvalue->{Block} eq 'Time' ) {
                    if ( $Xvalue->{TimeStart} && $Xvalue->{TimeStop} ) {
                        my $TimeStart = $TimeObject->TimeStamp2SystemTime(
                            String => $Xvalue->{TimeStart}
                        );
                        my $TimeStop = $TimeObject->TimeStamp2SystemTime(
                            String => $Xvalue->{TimeStop}
                        );
                        if ( !$TimeStart || !$TimeStop ) {
                            $XAxisFieldErrors{ $Xvalue->{Element} } = Translatable('The selected date is not valid.');
                        }
                        elsif ( $TimeStart > $TimeStop ) {
                            $XAxisFieldErrors{ $Xvalue->{Element} }
                                = Translatable('The selected end time is before the start time.');
                        }
                    }
                    elsif (
                        !$Xvalue->{TimeRelativeUnit}
                        || ( !$Xvalue->{TimeRelativeCount} && !$Xvalue->{TimeRelativeUpcomingCount} )
                        )
                    {
                        $XAxisFieldErrors{ $Xvalue->{Element} }
                            = Translatable('There is something wrong with your time selection.');
                    }

                    if ( !$Xvalue->{SelectedValues}[0] ) {
                        $XAxisFieldErrors{ $Xvalue->{Element} }
                            = Translatable('There is something wrong with your time selection.');
                    }
                    elsif ( $Xvalue->{Fixed} && $#{ $Xvalue->{SelectedValues} } > 0 ) {
                        $XAxisFieldErrors{ $Xvalue->{Element} }
                            = Translatable('There is something wrong with your time selection.');
                    }
                    else {
                        $SelectedXAxisTimeScaleValue = $Xvalue->{SelectedValues}[0];
                    }
                }
                elsif ( $Xvalue->{Block} eq 'SelectField' ) {
                    if ( $Xvalue->{Fixed} && $#{ $Xvalue->{SelectedValues} } > 0 ) {
                        $XAxisFieldErrors{ $Xvalue->{Element} } = Translatable(
                            'Please select only one element or allow modification at stat generation time.'
                        );
                    }
                    elsif ( $Xvalue->{Fixed} && !$Xvalue->{SelectedValues}[0] ) {
                        $XAxisFieldErrors{ $Xvalue->{Element} } = Translatable(
                            'Please select at least one value of this field or allow modification at stat generation time.'
                        );
                    }
                }

                $Flag = 1;
                last XVALUE;
            }
            if ( !$Flag ) {
                push @XAxisGeneralErrors, Translatable('Please select one element for the X-axis.');
            }
        }

        # Y Axis
        {
            my $Counter  = 0;
            my $TimeUsed = 0;
            VALUESERIES:
            for my $ValueSeries ( @{ $Stat{UseAsValueSeries} } ) {
                next VALUESERIES if !$ValueSeries->{Selected};

                if ( $ValueSeries->{Block} eq 'Time' || $ValueSeries->{Block} eq 'TimeExtended' ) {
                    if ( $ValueSeries->{Fixed} && $#{ $ValueSeries->{SelectedValues} } > 0 ) {
                        $YAxisFieldErrors{ $ValueSeries->{Element} }
                            = Translatable('There is something wrong with your time selection.');
                    }
                    elsif ( !$ValueSeries->{SelectedValues}[0] ) {
                        $YAxisFieldErrors{ $ValueSeries->{Element} }
                            = Translatable('There is something wrong with your time selection.');
                    }

                    my $TimeScale = $Self->_TimeScale(
                        SelectedXAxisValue => $SelectedXAxisTimeScaleValue,
                    );

                    if ( !IsHashRefWithData($TimeScale) ) {
                        $YAxisFieldErrors{ $ValueSeries->{Element} } = Translatable(
                            'No time scale value available for the current selected time scale value on the X axis.'
                        );
                    }

                    $TimeUsed++;
                }
                elsif ( $ValueSeries->{Block} eq 'SelectField' ) {
                    if ( $ValueSeries->{Fixed} && $#{ $ValueSeries->{SelectedValues} } > 0 ) {
                        $YAxisFieldErrors{ $ValueSeries->{Element} } = Translatable(
                            'Please select only one element or allow modification at stat generation time.'
                        );
                    }
                    elsif ( $ValueSeries->{Fixed} && !$ValueSeries->{SelectedValues}[0] ) {
                        $YAxisFieldErrors{ $ValueSeries->{Element} } = Translatable(
                            'Please select at least one value of this field or allow modification at stat generation time.'
                        );
                    }
                }

                $Counter++;
            }

            if ( $Counter > 1 && $TimeUsed ) {
                push @YAxisGeneralErrors, Translatable('You can only use one time element for the Y axis.');
            }
            elsif ( $Counter > 2 ) {
                push @YAxisGeneralErrors, Translatable('You can only use one or two elements for the Y axis.');
            }
        }

        # Restrictions
        {
            RESTRICTION:
            for my $Restriction ( @{ $Stat{UseAsRestriction} } ) {
                next RESTRICTION if !$Restriction->{Selected};

                if ( $Restriction->{Block} eq 'SelectField' ) {
                    if ( $Restriction->{Fixed} && $#{ $Restriction->{SelectedValues} } > 0 ) {
                        $RestrictionsFieldErrors{ $Restriction->{Element} } = Translatable(
                            'Please select only one element or allow modification at stat generation time.'
                        );
                    }
                    elsif ( !$Restriction->{SelectedValues}[0] ) {
                        $RestrictionsFieldErrors{ $Restriction->{Element} }
                            = Translatable('Please select at least one value of this field.');
                    }
                }
                elsif ( $Restriction->{Block} eq 'InputField' ) {
                    if ( !$Restriction->{SelectedValues}[0] && $Restriction->{Fixed} ) {
                        $RestrictionsFieldErrors{ $Restriction->{Element} }
                            = Translatable('Please provide a value or allow modification at stat generation time.');
                        last RESTRICTION;
                    }

                    # Show warning if restrictions contain stop words within ticket search.
                    my %StopWordFields = $Self->_StopWordFieldsGet();

                    if ( $StopWordFields{ $Restriction->{Element} } ) {
                        my $ErrorMessage = $Self->_StopWordErrorCheck(
                            $Restriction->{Element} => $Restriction->{SelectedValues}[0],
                        );
                        if ($ErrorMessage) {
                            $RestrictionsFieldErrors{ $Restriction->{Element} } = $ErrorMessage;
                        }
                    }

                }
                elsif ( $Restriction->{Block} eq 'Time' || $Restriction->{Block} eq 'TimeExtended' ) {
                    if ( $Restriction->{TimeStart} && $Restriction->{TimeStop} ) {
                        my $TimeStart = $TimeObject->TimeStamp2SystemTime(
                            String => $Restriction->{TimeStart}
                        );
                        my $TimeStop = $TimeObject->TimeStamp2SystemTime(
                            String => $Restriction->{TimeStop}
                        );
                        if ( !$TimeStart || !$TimeStop ) {
                            $RestrictionsFieldErrors{ $Restriction->{Element} }
                                = Translatable('The selected date is not valid.');
                        }
                        elsif ( $TimeStart > $TimeStop ) {
                            $RestrictionsFieldErrors{ $Restriction->{Element} }
                                = Translatable('The selected end time is before the start time.');
                        }
                    }
                    elsif (
                        !$Restriction->{TimeRelativeUnit}
                        || ( !$Restriction->{TimeRelativeCount} && !$Restriction->{TimeRelativeUpcomingCount} )
                        )
                    {
                        $RestrictionsFieldErrors{ $Restriction->{Element} }
                            = Translatable('There is something wrong with your time selection.');
                    }
                }
            }
        }

        # Check if the timeperiod is too big or the time scale too small. Also execute this check for
        #   non-fixed values because it is used in preview and cron stats generation mode.
        {
            XVALUE:
            for my $Xvalue ( @{ $Stat{UseAsXvalue} } ) {

                next XVALUE if !( $Xvalue->{Selected} && $Xvalue->{Block} eq 'Time' );

                my $Flag = 1;
                VALUESERIES:
                for my $ValueSeries ( @{ $Stat{UseAsValueSeries} } ) {
                    if ( $ValueSeries->{Selected} && $ValueSeries->{Block} eq 'Time' ) {
                        $Flag = 0;
                        last VALUESERIES;
                    }
                }

                last XVALUE if !$Flag;

                my $ScalePeriod        = 0;
                my $TimePeriod         = 0;
                my $TimeUpcomingPeriod = 0;

                my $Count = $Xvalue->{TimeScaleCount} ? $Xvalue->{TimeScaleCount} : 1;

                $ScalePeriod = $Self->_TimeInSeconds(
                    TimeUnit => $Xvalue->{SelectedValues}[0],
                );

                if ( !$ScalePeriod ) {
                    $XAxisFieldErrors{ $Xvalue->{Element} } = Translatable('Please select a time scale.');
                    last XVALUE;
                }

                if ( $Xvalue->{TimeStop} && $Xvalue->{TimeStart} ) {
                    $TimePeriod = (
                        $TimeObject->TimeStamp2SystemTime( String => $Xvalue->{TimeStop} )
                        )
                        - (
                        $TimeObject->TimeStamp2SystemTime( String => $Xvalue->{TimeStart} )
                        );
                }
                else {
                    $TimePeriod = $Xvalue->{TimeRelativeCount} * $Self->_TimeInSeconds(
                        TimeUnit => $Xvalue->{TimeRelativeUnit},
                    );
                    $TimeUpcomingPeriod = $Xvalue->{TimeRelativeUpcomingCount} * $Self->_TimeInSeconds(
                        TimeUnit => $Xvalue->{TimeRelativeUnit},
                    );
                }

                my $MaxAttr = $ConfigObject->Get('Stats::MaxXaxisAttributes') || 1000;
                if ( ( $TimePeriod + $TimeUpcomingPeriod ) / ( $ScalePeriod * $Count ) > $MaxAttr ) {
                    $XAxisFieldErrors{ $Xvalue->{Element} }
                        = Translatable('Your reporting time interval is too small, please use a larger time scale.');
                }

                last XVALUE;
            }
        }
    }

    if (
        !%GeneralSpecificationFieldErrors
        && !%XAxisFieldErrors
        && !@XAxisGeneralErrors
        && !%YAxisFieldErrors
        && !@YAxisGeneralErrors
        && !%RestrictionsFieldErrors
        )
    {
        return 1;
    }

    %{ $Param{Errors} } = (
        GeneralSpecificationFieldErrors => \%GeneralSpecificationFieldErrors,
        XAxisFieldErrors                => \%XAxisFieldErrors,
        XAxisGeneralErrors              => \@XAxisGeneralErrors,
        YAxisFieldErrors                => \%YAxisFieldErrors,
        YAxisGeneralErrors              => \@YAxisGeneralErrors,
        RestrictionsFieldErrors         => \%RestrictionsFieldErrors,
    );

    return;
}

sub _TimeOutput {
    my ( $Self, %Param ) = @_;

    # diffrent output types
    my %AllowedOutput = (
        Edit => 1,
        View => 1,
    );

    # check if the output type is given and allowed
    if ( !$Param{Output} || !$AllowedOutput{ $Param{Output} } ) {
        $Kernel::OM->Get('Kernel::System::Log')->Log(
            Priority => "error",
            Message  => '_TimeOutput: Need allowed output type!',
        );
    }

    # get layout object
    my $LayoutObject = $Kernel::OM->Get('Kernel::Output::HTML::Layout');

    my %TimeOutput;

    my %TimeScaleBuildSelection = $Self->_TimeScaleBuildSelection();

    my $Element   = $Param{Element};
    my $ElementID = $Element;

    # add the StatID to the ElementID for the view output
    if ( $Param{Output} eq 'View' && $Param{StatID} ) {
        $ElementID .= '-' . $Param{StatID} . '-' . $Param{OutputCounter};
    }

    if ( $Param{Use} ne 'UseAsValueSeries' ) {

        if ( $Param{Output} eq 'Edit' || ( $Param{TimeStart} && $Param{TimeStop} ) ) {

            # check if need params are available
            if ( !$Param{TimePeriodFormat} ) {
                $Kernel::OM->Get('Kernel::System::Log')->Log(
                    Priority => "error",
                    Message  => '_TimeOutput: Need TimePeriodFormat!',
                );
            }

            # get time object
            my $TimeObject = $Kernel::OM->Get('Kernel::System::Time');

            # get time
            my ( $Sec, $Min, $Hour, $Day, $Month, $Year ) = $TimeObject->SystemTime2Date(
                SystemTime => $TimeObject->SystemTime(),
            );
            my %TimeConfig;

            # default time configuration
            $TimeConfig{Format}                     = $Param{TimePeriodFormat};
            $TimeConfig{OverrideTimeZone}           = 1;
            $TimeConfig{ $Element . 'StartYear' }   = $Year - 1;
            $TimeConfig{ $Element . 'StartMonth' }  = 1;
            $TimeConfig{ $Element . 'StartDay' }    = 1;
            $TimeConfig{ $Element . 'StartHour' }   = 0;
            $TimeConfig{ $Element . 'StartMinute' } = 0;
            $TimeConfig{ $Element . 'StartSecond' } = 1;
            $TimeConfig{ $Element . 'StopYear' }    = $Year;
            $TimeConfig{ $Element . 'StopMonth' }   = 12;
            $TimeConfig{ $Element . 'StopDay' }     = 31;
            $TimeConfig{ $Element . 'StopHour' }    = 23;
            $TimeConfig{ $Element . 'StopMinute' }  = 59;
            $TimeConfig{ $Element . 'StopSecond' }  = 59;
            for (qw(Start Stop)) {
                $TimeConfig{Prefix} = $Element . $_;

                # time setting if available
                if (
                    $Param{ 'Time' . $_ }
                    && $Param{ 'Time' . $_ } =~ m{^(\d\d\d\d)-(\d\d)-(\d\d)\s(\d\d):(\d\d):(\d\d)$}xi
                    )
                {
                    $TimeConfig{ $Element . $_ . 'Year' }   = $1;
                    $TimeConfig{ $Element . $_ . 'Month' }  = $2;
                    $TimeConfig{ $Element . $_ . 'Day' }    = $3;
                    $TimeConfig{ $Element . $_ . 'Hour' }   = $4;
                    $TimeConfig{ $Element . $_ . 'Minute' } = $5;
                    $TimeConfig{ $Element . $_ . 'Second' } = $6;
                }
                $TimeOutput{ 'Time' . $_ } = $LayoutObject->BuildDateSelection(%TimeConfig);
            }
        }

        my %TimeCountData;
        for my $Counter ( 1 .. 60 ) {
            $TimeCountData{$Counter} = $Counter;
        }

        if ( $Param{Use} eq 'UseAsXvalue' ) {
            $TimeOutput{TimeScaleCount} = $LayoutObject->BuildSelection(
                Data       => \%TimeCountData,
                Name       => $Element . 'TimeScaleCount',
                ID         => $ElementID . '-TimeScaleCount',
                SelectedID => $Param{TimeScaleCount},
                Sort       => 'NumericKey',
                Class      => 'Modernize',
            );
        }

        if ( $Param{Output} eq 'Edit' || $Param{TimeRelativeUnit} ) {

            my @TimeCountList = qw(TimeRelativeCount TimeRelativeUpcomingCount);

            # add the zero for the time relative count selections
            $TimeCountData{0} = '-';

            for my $TimeCountName (@TimeCountList) {

                $TimeOutput{$TimeCountName} = $LayoutObject->BuildSelection(
                    Data       => \%TimeCountData,
                    Name       => $Element . $TimeCountName,
                    ID         => $ElementID . '-' . $TimeCountName,
                    SelectedID => $Param{$TimeCountName},
                    Sort       => 'NumericKey',
                    Class      => 'Modernize',
                );
            }

            $TimeOutput{TimeRelativeUnit} = $LayoutObject->BuildSelection(
                %TimeScaleBuildSelection,
                Name       => $Element . 'TimeRelativeUnit',
                ID         => $ElementID . '-TimeRelativeUnit',
                Class      => 'TimeRelativeUnit' . $Param{Output},
                SelectedID => $Param{TimeRelativeUnitLocalSelectedValue} // $Param{TimeRelativeUnit} // 'Day',
                Class      => 'Modernize',
            );
        }

        if ( $Param{TimeRelativeUnit} ) {
            $TimeOutput{CheckedRelative} = 'checked="checked"';
        }
        else {
            $TimeOutput{CheckedAbsolut} = 'checked="checked"';
        }
    }

    if ( $Param{Use} ne 'UseAsRestriction' ) {

        if ( $Param{Output} eq 'View' ) {
            $TimeOutput{TimeScaleYAxis} = $Self->_TimeScaleYAxis();
        }

        %TimeScaleBuildSelection = $Self->_TimeScaleBuildSelection(
            SelectedXAxisValue => $Param{SelectedXAxisValue},
            SortReverse        => 1,
        );

        $TimeOutput{TimeScaleUnit} = $LayoutObject->BuildSelection(
            %TimeScaleBuildSelection,
            Name       => $Element,
            ID         => $ElementID,
            Class      => 'Modernize TimeScale' . $Param{Output},
            SelectedID => $Param{TimeScaleUnitLocalSelectedValue} // $Param{SelectedValues}[0] // 'Day',
        );
        $TimeOutput{TimeScaleElementID} = $ElementID;
    }

    return %TimeOutput;
}

sub _TimeScaleBuildSelection {
    my ( $Self, %Param ) = @_;

    my %TimeScaleBuildSelection = (
        Data => {
            Second   => 'second(s)',
            Minute   => 'minute(s)',
            Hour     => 'hour(s)',
            Day      => 'day(s)',
            Week     => 'week(s)',
            Month    => 'month(s)',
            Quarter  => 'quarter(s)',
            HalfYear => 'half-year(s)',
            Year     => 'year(s)',
        },
        Sort           => 'IndividualKey',
        SortIndividual => [ 'Second', 'Minute', 'Hour', 'Day', 'Week', 'Month', 'Quarter', 'HalfYear', 'Year' ],
    );

    # special time scale handling
    if ( $Param{SelectedValue} || $Param{SelectedXAxisValue} ) {

        my $TimeScale = $Self->_TimeScale(%Param);

        # sort the time scale with the defined position
        my @TimeScaleSorted = sort { $TimeScale->{$a}->{Position} <=> $TimeScale->{$b}->{Position} } keys %{$TimeScale};

        # reverse the sorting
        if ( $Param{SortReverse} ) {
            @TimeScaleSorted
                = sort { $TimeScale->{$b}->{Position} <=> $TimeScale->{$a}->{Position} } keys %{$TimeScale};
        }

        my %TimeScaleData;

        ITEM:
        for my $Item (@TimeScaleSorted) {
            $TimeScaleData{$Item} = $TimeScale->{$Item}->{Value};
            last ITEM if $Param{SelectedValue} && $Param{SelectedValue} eq $Item;
        }

        $TimeScaleBuildSelection{Data} = \%TimeScaleData;
    }

    return %TimeScaleBuildSelection;
}

sub _TimeScale {
    my ( $Self, %Param ) = @_;

    my %TimeScale = (
        'Second' => {
            Position => 1,
            Value    => 'second(s)',
        },
        'Minute' => {
            Position => 2,
            Value    => 'minute(s)',
        },
        'Hour' => {
            Position => 3,
            Value    => 'hour(s)',
        },
        'Day' => {
            Position => 4,
            Value    => 'day(s)',
        },
        'Week' => {
            Position => 5,
            Value    => 'week(s)',
        },
        'Month' => {
            Position => 6,
            Value    => 'month(s)',
        },
        'Quarter' => {
            Position => 7,
            Value    => 'quarter(s)',
        },
        'HalfYear' => {
            Position => 8,
            Value    => 'half-year(s)',
        },
        'Year' => {
            Position => 9,
            Value    => 'year(s)',
        },
    );

    # allowed y axis time scale values for the selected x axis time value
    my $TimeScaleYAxis = $Self->_TimeScaleYAxis();

    if ( $Param{SelectedXAxisValue} ) {

        if ( IsArrayRefWithData( $TimeScaleYAxis->{ $Param{SelectedXAxisValue} } ) ) {
            %TimeScale
                = map { $_->{Key} => $TimeScale{ $_->{Key} } } @{ $TimeScaleYAxis->{ $Param{SelectedXAxisValue} } };
        }
        else {
            %TimeScale = ();
        }
    }

    return \%TimeScale;
}

sub _TimeScaleYAxis {
    my ( $Self, %Param ) = @_;

    # get layout object
    my $LayoutObject = $Kernel::OM->Get('Kernel::Output::HTML::Layout');

    # allowed y axis time scale values for the selected x axis time value
    # x axis value => [ y axis values ],
    my %TimeScaleYAxis = (
        'Second' => [
            {
                Key   => 'Minute',
                Value => $LayoutObject->{LanguageObject}->Translate('minute(s)'),
            },
        ],
        'Minute' => [
            {
                Key   => 'Hour',
                Value => $LayoutObject->{LanguageObject}->Translate('hour(s)'),
            },
        ],
        'Hour' => [
            {
                Key   => 'Day',
                Value => $LayoutObject->{LanguageObject}->Translate('day(s)'),
            },
        ],
        'Day' => [
            {
                Key   => 'Month',
                Value => $LayoutObject->{LanguageObject}->Translate('month(s)'),
            },
        ],
        'Week' => [
            {
                Key   => 'Week',
                Value => $LayoutObject->{LanguageObject}->Translate('week(s)'),
            },
        ],
        'Month' => [
            {
                Key   => 'Year',
                Value => $LayoutObject->{LanguageObject}->Translate('year(s)'),
            },
        ],
        'Quarter' => [
            {
                Key   => 'Year',
                Value => $LayoutObject->{LanguageObject}->Translate('year(s)'),
            },
        ],
        'HalfYear' => [
            {
                Key   => 'Year',
                Value => $LayoutObject->{LanguageObject}->Translate('year(s)'),
            },
        ],
    );

    return \%TimeScaleYAxis;
}

sub _TimeZoneBuildSelection {
    my ( $Self, %Param ) = @_;

    my %TimeZoneBuildSelection = (
        Data => {
            '0'   => '+ 0',
            '+1'  => '+ 1',
            '+2'  => '+ 2',
            '+3'  => '+ 3',
            '+4'  => '+ 4',
            '+5'  => '+ 5',
            '+6'  => '+ 6',
            '+7'  => '+ 7',
            '+8'  => '+ 8',
            '+9'  => '+ 9',
            '+10' => '+10',
            '+11' => '+11',
            '+12' => '+12',
            '-1'  => '- 1',
            '-2'  => '- 2',
            '-3'  => '- 3',
            '-4'  => '- 4',
            '-5'  => '- 5',
            '-6'  => '- 6',
            '-7'  => '- 7',
            '-8'  => '- 8',
            '-9'  => '- 9',
            '-10' => '-10',
            '-11' => '-11',
            '-12' => '-12',
        },
    );

    return %TimeZoneBuildSelection;
}

=item _ColumnAndRowTranslation()

translate the column and row name if needed

    $StatsViewObject->_ColumnAndRowTranslation(
        StatArrayRef => $StatArrayRef,
        HeadArrayRef => $HeadArrayRef,
        StatRef      => $StatRef,
        ExchangeAxis => 1 | 0,
    );

=cut

sub _ColumnAndRowTranslation {
    my ( $Self, %Param ) = @_;

    # check if need params are available
    for my $NeededParam (qw(StatArrayRef HeadArrayRef StatRef)) {
        if ( !$Param{$NeededParam} ) {
            $Kernel::OM->Get('Kernel::System::Log')->Log(
                Priority => "error",
                Message  => "_ColumnAndRowTranslation: Need $NeededParam!"
            );
        }
    }

    # get config object
    my $ConfigObject = $Kernel::OM->Get('Kernel::Config');

    # create language object
    $Kernel::OM->ObjectParamAdd(
        'Kernel::Language' => {
            UserLanguage => $Param{UserLanguage} || $ConfigObject->Get('DefaultLanguage') || 'en',
            }
    );
    my $LanguageObject = $Kernel::OM->Get('Kernel::Language');

    # find out, if the column or row names should be translated
    my %Translation;
    my %Sort;

    for my $Use (qw( UseAsXvalue UseAsValueSeries )) {
        if (
            $Param{StatRef}->{StatType} eq 'dynamic'
            && $Param{StatRef}->{$Use}
            && ref( $Param{StatRef}->{$Use} ) eq 'ARRAY'
            )
        {
            my @Array = @{ $Param{StatRef}->{$Use} };

            ELEMENT:
            for my $Element (@Array) {
                next ELEMENT if !$Element->{SelectedValues};

                if ( $Element->{Translation} && $Element->{Block} eq 'Time' ) {
                    $Translation{$Use} = 'Time';
                }
                elsif ( $Element->{Translation} ) {
                    $Translation{$Use} = 'Common';
                }
                else {
                    $Translation{$Use} = '';
                }

                if (
                    $Element->{Translation}
                    && $Element->{Block} ne 'Time'
                    && !$Element->{SortIndividual}
                    )
                {
                    $Sort{$Use} = 1;
                }
                last ELEMENT;
            }
        }
    }

    # check if the axis are changed
    if ( $Param{ExchangeAxis} ) {
        my $UseAsXvalueOld = $Translation{UseAsXvalue};
        $Translation{UseAsXvalue}      = $Translation{UseAsValueSeries};
        $Translation{UseAsValueSeries} = $UseAsXvalueOld;

        my $SortUseAsXvalueOld = $Sort{UseAsXvalue};
        $Sort{UseAsXvalue}      = $Sort{UseAsValueSeries};
        $Sort{UseAsValueSeries} = $SortUseAsXvalueOld;
    }

    # translate the headline
    $Param{HeadArrayRef}->[0] = $LanguageObject->Translate( $Param{HeadArrayRef}->[0] );

    if ( $Translation{UseAsXvalue} && $Translation{UseAsXvalue} ne 'Time' ) {
        for my $Word ( @{ $Param{HeadArrayRef} } ) {
            $Word = $LanguageObject->Translate($Word);
        }
    }

    # sort the headline
    if ( $Sort{UseAsXvalue} ) {
        my @HeadOld = @{ $Param{HeadArrayRef} };
        shift @HeadOld;    # because the first value is no sortable column name

        # special handling if the sumfunction is used
        my $SumColRef;
        if ( $Param{StatRef}->{SumRow} ) {
            $SumColRef = pop @HeadOld;
        }

        # sort
        my @SortedHead = sort { $a cmp $b } @HeadOld;

        # special handling if the sumfunction is used
        if ( $Param{StatRef}->{SumCol} ) {
            push @SortedHead, $SumColRef;
            push @HeadOld,    $SumColRef;
        }

        # add the row names to the new StatArray
        my @StatArrayNew;
        for my $Row ( @{ $Param{StatArrayRef} } ) {
            push @StatArrayNew, [ $Row->[0] ];
        }

        # sort the values
        for my $ColumnName (@SortedHead) {
            my $Counter = 0;
            COLUMNNAMEOLD:
            for my $ColumnNameOld (@HeadOld) {
                $Counter++;
                next COLUMNNAMEOLD if $ColumnNameOld ne $ColumnName;

                for my $RowLine ( 0 .. $#StatArrayNew ) {
                    push @{ $StatArrayNew[$RowLine] }, $Param{StatArrayRef}->[$RowLine]->[$Counter];
                }
                last COLUMNNAMEOLD;
            }
        }

        # bring the data back to the references
        unshift @SortedHead, $Param{HeadArrayRef}->[0];
        @{ $Param{HeadArrayRef} } = @SortedHead;
        @{ $Param{StatArrayRef} } = @StatArrayNew;
    }

    # translate the row description
    if ( $Translation{UseAsValueSeries} && $Translation{UseAsValueSeries} ne 'Time' ) {

        # translate
        for my $Word ( @{ $Param{StatArrayRef} } ) {
            $Word->[0] = $LanguageObject->Translate( $Word->[0] );
        }
    }

    # sort the row description
    if ( $Sort{UseAsValueSeries} ) {

        # special handling if the sumfunction is used
        my $SumRowArrayRef;
        if ( $Param{StatRef}->{SumRow} ) {
            $SumRowArrayRef = pop @{ $Param{StatArrayRef} };
        }

        # sort
        my $DisableDefaultResultSort = grep {
            $_->{DisableDefaultResultSort}
                && $_->{DisableDefaultResultSort} == 1
        } @{ $Param{StatRef}->{UseAsXvalue} };

        if ( !$DisableDefaultResultSort ) {
            @{ $Param{StatArrayRef} } = sort { $a->[0] cmp $b->[0] } @{ $Param{StatArrayRef} };
        }

        # special handling if the sumfunction is used
        if ( $Param{StatRef}->{SumRow} ) {
            push @{ $Param{StatArrayRef} }, $SumRowArrayRef;
        }
    }

    return 1;
}

# ATTENTION: this function delivers only approximations!!!
sub _TimeInSeconds {
    my ( $Self, %Param ) = @_;

    # check if need params are available
    if ( !$Param{TimeUnit} ) {
        $Kernel::OM->Get('Kernel::System::Log')->Log(
            Priority => "error",
            Message  => '_TimeInSeconds: Need TimeUnit!',
        );
        return;
    }

    my %TimeInSeconds = (
        Year     => 60 * 60 * 24 * 365,
        HalfYear => 60 * 60 * 24 * 182,
        Quarter  => 60 * 60 * 24 * 91,
        Month    => 60 * 60 * 24 * 30,
        Week     => 60 * 60 * 24 * 7,
        Day      => 60 * 60 * 24,
        Hour     => 60 * 60,
        Minute   => 60,
        Second   => 1,
    );

    return $TimeInSeconds{ $Param{TimeUnit} };
}

sub _GetSelectedXAxisTimeScaleValue {
    my ( $Self, %Param ) = @_;

    my $SelectedXAxisTimeScaleValue;

    for ( @{ $Param{Stat}->{UseAsXvalue} } ) {

        if ( $_->{Selected} && $_->{Block} eq 'Time' ) {
            $SelectedXAxisTimeScaleValue = $_->{SelectedValues}[0];
        }
    }

    return $SelectedXAxisTimeScaleValue;
}

sub _StopWordErrorCheck {
    my ( $Self, %Param ) = @_;

    # get needed objects
    my $LayoutObject = $Kernel::OM->Get('Kernel::Output::HTML::Layout');
    my $TicketObject = $Kernel::OM->Get('Kernel::System::Ticket');

    if ( !%Param ) {
        $LayoutObject->FatalError( Message => "Got no values to check." );
    }

    my %StopWordsServerErrors;
    if ( !$TicketObject->SearchStringStopWordsUsageWarningActive() ) {
        return %StopWordsServerErrors;
    }

    my %SearchStrings;

    FIELD:
    for my $Field ( sort keys %Param ) {
        next FIELD if !defined $Param{$Field};
        next FIELD if !length $Param{$Field};

        $SearchStrings{$Field} = $Param{$Field};
    }

    my $ErrorMessage;

    if (%SearchStrings) {

        my $StopWords = $TicketObject->SearchStringStopWordsFind(
            SearchStrings => \%SearchStrings
        );

        FIELD:
        for my $Field ( sort keys %{$StopWords} ) {
            next FIELD if !defined $StopWords->{$Field};
            next FIELD if ref $StopWords->{$Field} ne 'ARRAY';
            next FIELD if !@{ $StopWords->{$Field} };

            $ErrorMessage = $LayoutObject->{LanguageObject}->Translate(
                'Please remove the following words because they cannot be used for the ticket restrictions: %s.',
                join( ',', sort @{ $StopWords->{$Field} } ),
            );
        }
    }

    return $ErrorMessage;
}

sub _StopWordFieldsGet {
    my ( $Self, %Param ) = @_;

    if ( !$Kernel::OM->Get('Kernel::System::Ticket')->SearchStringStopWordsUsageWarningActive() ) {
        return ();
    }

    my %StopWordFields = (
        'From'    => 1,
        'To'      => 1,
        'Cc'      => 1,
        'Subject' => 1,
        'Body'    => 1,
    );

    return %StopWordFields;
}

1;

=back

=head1 TERMS AND CONDITIONS

This software is part of the OTRS project (L<http://otrs.org/>).

This software comes with ABSOLUTELY NO WARRANTY. For details, see
the enclosed file COPYING for license information (AGPL). If you
did not receive this file, see L<http://www.gnu.org/licenses/agpl.txt>.

=cut