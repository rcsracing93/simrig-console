#requires -Version 7.0
<#
    SimRigConsole.View.ps1

    XAML and view functions for SimRig Console v4.0. This file holds only
    presentation: it parses the XAML, exposes named elements, and updates
    them from plain values the controller passes in. It never calls
    Engine, Probe or Actions functions, and never reads or writes system
    state. Every function is safe to call before the window exists or
    with a name that is not in the XAML - it logs to the verbose stream
    and returns.
#>

Set-StrictMode -Version 3.0

# ---------------------------------------------------------------------------
# XAML
# ---------------------------------------------------------------------------

$script:ConsoleXaml = @'
<Window
    xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
    xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
    Title="SimRig Console"
    ThemeMode="System"
    MinWidth="900"
    MinHeight="620"
    Width="1100"
    Height="760">

    <Window.Resources>

        <Style x:Key="BadgeTextStyle" TargetType="TextBlock">
            <Setter Property="FontSize" Value="11" />
            <Setter Property="FontWeight" Value="SemiBold" />
            <Setter Property="VerticalAlignment" Value="Center" />
            <Setter Property="HorizontalAlignment" Value="Center" />
            <Setter Property="Foreground" Value="{DynamicResource TextFillColorPrimaryBrush}" />
        </Style>

        <Style x:Key="BadgeBorderStyle" TargetType="Border">
            <Setter Property="CornerRadius" Value="8" />
            <Setter Property="Padding" Value="8,2" />
            <Setter Property="HorizontalAlignment" Value="Right" />
            <Setter Property="Background" Value="{DynamicResource CardStrokeColorDefaultBrush}" />
            <Style.Triggers>
                <DataTrigger Binding="{Binding Verdict}" Value="Pass">
                    <Setter Property="Background" Value="{DynamicResource SystemFillColorSuccessBackgroundBrush}" />
                </DataTrigger>
                <DataTrigger Binding="{Binding Verdict}" Value="Match">
                    <Setter Property="Background" Value="{DynamicResource SystemFillColorSuccessBackgroundBrush}" />
                </DataTrigger>
                <DataTrigger Binding="{Binding Verdict}" Value="OK">
                    <Setter Property="Background" Value="{DynamicResource SystemFillColorSuccessBackgroundBrush}" />
                </DataTrigger>
                <DataTrigger Binding="{Binding Verdict}" Value="Fail">
                    <Setter Property="Background" Value="{DynamicResource SystemFillColorCriticalBackgroundBrush}" />
                </DataTrigger>
                <DataTrigger Binding="{Binding Verdict}" Value="Revert">
                    <Setter Property="Background" Value="{DynamicResource SystemFillColorCriticalBackgroundBrush}" />
                </DataTrigger>
                <DataTrigger Binding="{Binding Verdict}" Value="Warn">
                    <Setter Property="Background" Value="{DynamicResource SystemFillColorCautionBackgroundBrush}" />
                </DataTrigger>
                <DataTrigger Binding="{Binding Verdict}" Value="Note">
                    <Setter Property="Background" Value="{DynamicResource SystemFillColorCautionBackgroundBrush}" />
                </DataTrigger>
                <DataTrigger Binding="{Binding Verdict}" Value="Manual">
                    <Setter Property="Background" Value="{DynamicResource SystemFillColorAttentionBackgroundBrush}" />
                </DataTrigger>
                <DataTrigger Binding="{Binding Verdict}" Value="Info">
                    <Setter Property="Background" Value="{DynamicResource SystemFillColorAttentionBackgroundBrush}" />
                </DataTrigger>
                <DataTrigger Binding="{Binding Verdict}" Value="Waiting">
                    <Setter Property="Background" Value="{DynamicResource SystemFillColorAttentionBackgroundBrush}" />
                </DataTrigger>
                <DataTrigger Binding="{Binding Verdict}" Value="Skipped">
                    <Setter Property="Background" Value="{DynamicResource SystemFillColorAttentionBackgroundBrush}" />
                </DataTrigger>
            </Style.Triggers>
        </Style>

        <Style x:Key="BadgeBorderSeverityStyle" TargetType="Border" BasedOn="{StaticResource BadgeBorderStyle}">
            <Style.Triggers>
                <DataTrigger Binding="{Binding Severity}" Value="OK">
                    <Setter Property="Background" Value="{DynamicResource SystemFillColorSuccessBackgroundBrush}" />
                </DataTrigger>
                <DataTrigger Binding="{Binding Severity}" Value="Revert">
                    <Setter Property="Background" Value="{DynamicResource SystemFillColorCriticalBackgroundBrush}" />
                </DataTrigger>
                <DataTrigger Binding="{Binding Severity}" Value="Note">
                    <Setter Property="Background" Value="{DynamicResource SystemFillColorCautionBackgroundBrush}" />
                </DataTrigger>
                <DataTrigger Binding="{Binding Severity}" Value="Info">
                    <Setter Property="Background" Value="{DynamicResource SystemFillColorAttentionBackgroundBrush}" />
                </DataTrigger>
            </Style.Triggers>
        </Style>

        <Style x:Key="CardBorderStyle" TargetType="Border">
            <Setter Property="Background" Value="{DynamicResource CardBackgroundFillColorDefaultBrush}" />
            <Setter Property="BorderBrush" Value="{DynamicResource CardStrokeColorDefaultBrush}" />
            <Setter Property="BorderThickness" Value="1" />
            <Setter Property="CornerRadius" Value="4" />
            <Setter Property="Padding" Value="14,10" />
            <Setter Property="Margin" Value="0,0,0,6" />
        </Style>

        <Style x:Key="MonoTextStyle" TargetType="TextBlock">
            <Setter Property="FontFamily" Value="Cascadia Mono, Consolas" />
            <Setter Property="FontSize" Value="12" />
            <Setter Property="Foreground" Value="{DynamicResource TextFillColorPrimaryBrush}" />
        </Style>

        <!-- The shield on every control that raises a UAC prompt: the Windows UX rule
             for elevation, and the beta.1 review's section 3. It is a ContentTemplate
             rather than a Style, because the accent style is set at run time by
             Show-ButtonSet and a button has only one Style - a locally set
             ContentTemplate survives that change. Content stays a plain string, so the
             string table and the label tests keep working. -->
        <DataTemplate x:Key="ShieldContentTemplate">
            <StackPanel Orientation="Horizontal">
                <TextBlock Text="&#xEA18;" FontFamily="Segoe Fluent Icons" FontSize="14"
                           Margin="0,0,6,0" VerticalAlignment="Center" />
                <TextBlock Text="{Binding}" VerticalAlignment="Center" />
            </StackPanel>
        </DataTemplate>

        <DataTemplate x:Key="ToolRowTemplate">
            <Border Style="{StaticResource CardBorderStyle}">
                <Grid>
                    <Grid.ColumnDefinitions>
                        <ColumnDefinition Width="*" />
                        <ColumnDefinition Width="Auto" />
                    </Grid.ColumnDefinitions>
                    <StackPanel Grid.Column="0">
                        <TextBlock Text="{Binding Name}" FontWeight="SemiBold" Foreground="{DynamicResource TextFillColorPrimaryBrush}" />
                        <TextBlock Text="{Binding Detail}" FontSize="12" Foreground="{DynamicResource TextFillColorSecondaryBrush}" />
                        <TextBlock Text="{Binding Value}" FontSize="11" Foreground="{DynamicResource TextFillColorSecondaryBrush}" />
                    </StackPanel>
                    <Button x:Name="BtnInstallTool" Grid.Column="1" Content="{Binding InstallLabel}"
                            Tag="{Binding Source}"
                            Visibility="{Binding InstallVisibility}"
                            AutomationProperties.Name="{Binding InstallAutomationName}" />
                </Grid>
            </Border>
        </DataTemplate>

        <DataTemplate x:Key="CheckRowTemplate">
            <Border Style="{StaticResource CardBorderStyle}">
                <Grid>
                    <Grid.ColumnDefinitions>
                        <ColumnDefinition Width="*" />
                        <ColumnDefinition Width="Auto" />
                        <ColumnDefinition Width="Auto" />
                    </Grid.ColumnDefinitions>
                    <StackPanel Grid.Column="0" VerticalAlignment="Center">
                        <TextBlock Text="{Binding Name}" FontSize="13" FontWeight="SemiBold"
                                   Foreground="{DynamicResource TextFillColorPrimaryBrush}" />
                        <TextBlock Text="{Binding Detail}" FontSize="12"
                                   Foreground="{DynamicResource TextFillColorSecondaryBrush}" />
                    </StackPanel>
                    <TextBlock Grid.Column="1" Text="{Binding Value}" Style="{StaticResource MonoTextStyle}"
                               Margin="10,0" VerticalAlignment="Center" HorizontalAlignment="Right" />
                    <Border Grid.Column="2" Style="{StaticResource BadgeBorderStyle}" VerticalAlignment="Center">
                        <TextBlock Text="{Binding Verdict}" Style="{StaticResource BadgeTextStyle}" />
                    </Border>
                </Grid>
            </Border>
        </DataTemplate>

        <DataTemplate x:Key="TimelineRowTemplate">
            <Border Style="{StaticResource CardBorderStyle}">
                <Grid>
                    <Grid.ColumnDefinitions>
                        <ColumnDefinition Width="Auto" />
                        <ColumnDefinition Width="*" />
                        <ColumnDefinition Width="Auto" />
                    </Grid.ColumnDefinitions>
                    <TextBlock Grid.Column="0" Text="{Binding Time}" Style="{StaticResource MonoTextStyle}"
                               VerticalAlignment="Center" Margin="0,0,10,0" />
                    <TextBlock Grid.Column="1" Text="{Binding Message}" FontSize="12"
                               Foreground="{DynamicResource TextFillColorPrimaryBrush}"
                               VerticalAlignment="Center" TextWrapping="Wrap" />
                    <Border Grid.Column="2" Style="{StaticResource BadgeBorderSeverityStyle}" VerticalAlignment="Center">
                        <TextBlock Text="{Binding Severity}" Style="{StaticResource BadgeTextStyle}" />
                    </Border>
                </Grid>
            </Border>
        </DataTemplate>

        <DataTemplate x:Key="SideKeyRowTemplate">
            <Grid Margin="0,0,0,6">
                <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="*" />
                    <ColumnDefinition Width="Auto" />
                </Grid.ColumnDefinitions>
                <TextBlock Grid.Column="0" Text="{Binding Key}" FontSize="12"
                           Foreground="{DynamicResource TextFillColorTertiaryBrush}" />
                <TextBlock Grid.Column="1" Text="{Binding Value}" Style="{StaticResource MonoTextStyle}"
                           HorizontalAlignment="Right" />
            </Grid>
        </DataTemplate>

    </Window.Resources>

    <Grid>
    <Grid Margin="24,4,24,22">
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto" />
            <RowDefinition Height="Auto" />
            <RowDefinition Height="Auto" />
            <RowDefinition Height="*" />
            <RowDefinition Height="Auto" />
        </Grid.RowDefinitions>

        <!-- Heading row -->
        <Grid Grid.Row="0" Margin="0,0,0,14">
            <Grid.ColumnDefinitions>
                <ColumnDefinition Width="*" />
                <ColumnDefinition Width="Auto" />
            </Grid.ColumnDefinitions>
            <StackPanel Grid.Column="0">
                <TextBlock x:Name="TxtTitle" Text="SimRig Console" FontSize="28" FontWeight="SemiBold"
                           Foreground="{DynamicResource TextFillColorPrimaryBrush}" />
                <!-- RF-3c. One line. A subtitle that does not fit ends with "..." and is
                     not cut in the middle of a letter. The texts are short: a subtitle
                     says a count, and the rows say the names. -->
                <TextBlock x:Name="TxtSubtitle" FontSize="13" TextTrimming="CharacterEllipsis"
                           Foreground="{DynamicResource TextFillColorSecondaryBrush}" />
            </StackPanel>
            <StackPanel Grid.Column="1" HorizontalAlignment="Right" VerticalAlignment="Top">
                <TextBlock x:Name="TxtRig" FontSize="12" HorizontalAlignment="Right"
                           Foreground="{DynamicResource TextFillColorSecondaryBrush}" />
                <TextBlock x:Name="TxtSession" FontSize="12" HorizontalAlignment="Right"
                           Foreground="{DynamicResource TextFillColorSecondaryBrush}" />
            </StackPanel>
        </Grid>

        <!-- Stepper -->
        <UniformGrid Grid.Row="1" Rows="1" Columns="5" Margin="0,0,0,14">
            <Border x:Name="Step1" BorderThickness="0" Margin="0,0,4,0">
                <Grid>
                    <Grid.RowDefinitions>
                        <RowDefinition Height="*" />
                        <RowDefinition Height="3" />
                    </Grid.RowDefinitions>
                    <StackPanel Grid.Row="0" Margin="8,6">
                        <TextBlock x:Name="StepText1" Text="Waiting" FontSize="11"
                                   Foreground="{DynamicResource TextFillColorTertiaryBrush}" />
                        <TextBlock Text="Preflight" FontSize="13" FontWeight="SemiBold"
                                   Foreground="{DynamicResource TextFillColorPrimaryBrush}" />
                    </StackPanel>
                    <Border Grid.Row="1" Background="{DynamicResource ControlStrokeColorDefaultBrush}" />
                </Grid>
            </Border>
            <Border x:Name="Step2" BorderThickness="0" Margin="4,0">
                <Grid>
                    <Grid.RowDefinitions>
                        <RowDefinition Height="*" />
                        <RowDefinition Height="3" />
                    </Grid.RowDefinitions>
                    <StackPanel Grid.Row="0" Margin="8,6">
                        <TextBlock x:Name="StepText2" Text="Waiting" FontSize="11"
                                   Foreground="{DynamicResource TextFillColorTertiaryBrush}" />
                        <TextBlock Text="Quiet" FontSize="13" FontWeight="SemiBold"
                                   Foreground="{DynamicResource TextFillColorPrimaryBrush}" />
                    </StackPanel>
                    <Border Grid.Row="1" Background="{DynamicResource ControlStrokeColorDefaultBrush}" />
                </Grid>
            </Border>
            <Border x:Name="Step3" BorderThickness="0" Margin="4,0">
                <Grid>
                    <Grid.RowDefinitions>
                        <RowDefinition Height="*" />
                        <RowDefinition Height="3" />
                    </Grid.RowDefinitions>
                    <StackPanel Grid.Row="0" Margin="8,6">
                        <TextBlock x:Name="StepText3" Text="Waiting" FontSize="11"
                                   Foreground="{DynamicResource TextFillColorTertiaryBrush}" />
                        <TextBlock Text="Race watch" FontSize="13" FontWeight="SemiBold"
                                   Foreground="{DynamicResource TextFillColorPrimaryBrush}" />
                    </StackPanel>
                    <Border Grid.Row="1" Background="{DynamicResource ControlStrokeColorDefaultBrush}" />
                </Grid>
            </Border>
            <Border x:Name="Step4" BorderThickness="0" Margin="4,0">
                <Grid>
                    <Grid.RowDefinitions>
                        <RowDefinition Height="*" />
                        <RowDefinition Height="3" />
                    </Grid.RowDefinitions>
                    <StackPanel Grid.Row="0" Margin="8,6">
                        <TextBlock x:Name="StepText4" Text="Waiting" FontSize="11"
                                   Foreground="{DynamicResource TextFillColorTertiaryBrush}" />
                        <TextBlock Text="Restore" FontSize="13" FontWeight="SemiBold"
                                   Foreground="{DynamicResource TextFillColorPrimaryBrush}" />
                    </StackPanel>
                    <Border Grid.Row="1" Background="{DynamicResource ControlStrokeColorDefaultBrush}" />
                </Grid>
            </Border>
            <Border x:Name="Step5" BorderThickness="0" Margin="4,0,0,0">
                <Grid>
                    <Grid.RowDefinitions>
                        <RowDefinition Height="*" />
                        <RowDefinition Height="3" />
                    </Grid.RowDefinitions>
                    <StackPanel Grid.Row="0" Margin="8,6">
                        <TextBlock x:Name="StepText5" Text="Waiting" FontSize="11"
                                   Foreground="{DynamicResource TextFillColorTertiaryBrush}" />
                        <TextBlock Text="Copy" FontSize="13" FontWeight="SemiBold"
                                   Foreground="{DynamicResource TextFillColorPrimaryBrush}" />
                    </StackPanel>
                    <Border Grid.Row="1" Background="{DynamicResource ControlStrokeColorDefaultBrush}" />
                </Grid>
            </Border>
        </UniformGrid>

        <!-- Banner -->
        <!-- RF-3. The buttons are in a row of their own, below the title and the text.
             Until 2026-10-02 they were in a third column with Width="Auto". An Auto
             column is measured with no width limit, so the WrapPanel did not wrap and
             took the width of each visible button in one line. The text column got what
             was left (22.3 of 1028, measured in tier B run 37025572541), the text
             wrapped to a column 7511.9 high, and the row of the check list got no
             height. Now the text has the full width of the banner, and the WrapPanel
             is in the "*" column, so it has a width limit and wraps. -->
        <Border x:Name="Banner" Grid.Row="2" CornerRadius="4" Padding="14,12" Margin="0,0,0,14"
                Background="{DynamicResource SystemFillColorAttentionBackgroundBrush}">
            <Grid>
                <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="Auto" />
                    <ColumnDefinition Width="*" />
                </Grid.ColumnDefinitions>
                <Grid.RowDefinitions>
                    <RowDefinition Height="Auto" />
                    <RowDefinition Height="Auto" />
                </Grid.RowDefinitions>
                <Border Grid.Column="0" Grid.Row="0" Width="18" Height="18" CornerRadius="9" VerticalAlignment="Top"
                        Margin="0,0,10,0" Background="{DynamicResource AccentFillColorDefaultBrush}">
                    <TextBlock x:Name="BannerIcon" Text="i" FontSize="11" FontWeight="Bold"
                               HorizontalAlignment="Center" VerticalAlignment="Center"
                               Foreground="{DynamicResource TextFillColorPrimaryBrush}" />
                </Border>
                <StackPanel Grid.Column="1" Grid.Row="0">
                    <!-- One line, no wrapping (Cowork verdict on 0f0fd40, answer 6). -->
                    <TextBlock x:Name="BannerTitle" FontSize="14" FontWeight="SemiBold"
                               Foreground="{DynamicResource TextFillColorPrimaryBrush}" />
                    <!-- A maximum height, so that no text of any length can take the row of
                         the check list to nothing again. A text that is higher gets a
                         scroll bar, and the build run is red for that on the first screen. -->
                    <ScrollViewer x:Name="BannerTextScroll" MaxHeight="96" VerticalScrollBarVisibility="Auto"
                                  HorizontalScrollBarVisibility="Disabled">
                        <TextBlock x:Name="BannerText" FontSize="12" TextWrapping="Wrap"
                                   Foreground="{DynamicResource TextFillColorSecondaryBrush}" />
                    </ScrollViewer>
                </StackPanel>
                <!-- Each button has a top and a bottom margin of 3, so two lines of buttons
                     do not touch (the rig has 9 buttons with a GPU steering failure, and
                     they wrap). The panel takes the 3 off at its top and its bottom, so a
                     banner with one line of buttons has the height of before. -->
                <WrapPanel Grid.Column="1" Grid.Row="1" Margin="-4,7,0,-3" HorizontalAlignment="Left">
                    <!-- Order: primary first, then secondary, then the two that are
                         always last (Dry run, Open log). One accent per mode is set at
                         run time by Show-ButtonSet, so no accent style is set here.
                         ContentTemplate marks the ones that raise a UAC prompt. -->
                    <Button x:Name="BtnStart" Content="Quiet and start iRacing" Margin="4,3"
                            ContentTemplate="{StaticResource ShieldContentTemplate}" />
                    <Button x:Name="BtnStartTools" Content="Quiet and start iRacing + capture tools" Margin="4,3"
                            ContentTemplate="{StaticResource ShieldContentTemplate}" />
                    <Button x:Name="BtnStartAnyway" Content="Start anyway" Margin="4,3"
                            ContentTemplate="{StaticResource ShieldContentTemplate}" />
                    <Button x:Name="BtnStartAnywayTools" Content="Start anyway with capture tools" Margin="4,3"
                            ContentTemplate="{StaticResource ShieldContentTemplate}" />
                    <Button x:Name="BtnFixGpu" Content="Fix GPU steering" Margin="4,3"
                            ContentTemplate="{StaticResource ShieldContentTemplate}" />
                    <Button x:Name="BtnRecheck" Content="Re-check" Margin="4,3" />
                    <Button x:Name="BtnEndSession" Content="End session" Margin="4,3"
                            ContentTemplate="{StaticResource ShieldContentTemplate}" />
                    <Button x:Name="BtnPush" Content="Push" Margin="4,3" />
                    <Button x:Name="BtnRestore" Content="Restore" Margin="4,3"
                            ContentTemplate="{StaticResource ShieldContentTemplate}" />
                    <Button x:Name="BtnFix" Content="Fix" Margin="4,3"
                            ContentTemplate="{StaticResource ShieldContentTemplate}" />
                    <Button x:Name="BtnApplyTuning" Content="Apply tuning" Margin="4,3"
                            AutomationProperties.Name="Apply tuning"
                            ContentTemplate="{StaticResource ShieldContentTemplate}" />
                    <Button x:Name="BtnUndoTuning" Content="Undo tuning" Margin="4,3"
                            AutomationProperties.Name="Undo tuning"
                            ContentTemplate="{StaticResource ShieldContentTemplate}" />
                    <Button x:Name="BtnSaveLatencyMon" Content="Save LatencyMon report from clipboard" Margin="4,3" />
                    <Button x:Name="BtnOpenFolder" Content="Open folder" Margin="4,3" />
                    <Button x:Name="BtnOpenReport" Content="Open report" Margin="4,3" />
                    <Button x:Name="BtnUndo" Content="Undo every change this app made" Margin="4,3"
                            ContentTemplate="{StaticResource ShieldContentTemplate}" />
                    <Button x:Name="BtnDryRun" Content="Dry run" Margin="4,3" />
                    <Button x:Name="BtnOpenLog" Content="Open log" Margin="4,3" />
                </WrapPanel>
            </Grid>
        </Border>

        <!-- Body: two columns -->
        <Grid Grid.Row="3">
            <Grid.ColumnDefinitions>
                <ColumnDefinition Width="1.4*" />
                <ColumnDefinition Width="12" />
                <ColumnDefinition Width="1*" />
            </Grid.ColumnDefinitions>

            <ScrollViewer Grid.Column="0" VerticalScrollBarVisibility="Auto">
                <StackPanel>
                    <TextBlock x:Name="ListLeftTitle" Text="Checks" FontSize="14" FontWeight="SemiBold"
                               Margin="0,0,0,8" Foreground="{DynamicResource TextFillColorPrimaryBrush}" />
                    <ItemsControl x:Name="CheckList" ItemTemplate="{StaticResource CheckRowTemplate}" />
                </StackPanel>
            </ScrollViewer>

            <Border Grid.Column="2" Style="{StaticResource CardBorderStyle}" Padding="16" Margin="0"
                    VerticalAlignment="Stretch">
                <ScrollViewer VerticalScrollBarVisibility="Auto">
                    <StackPanel>
                        <TextBlock x:Name="ListRightTitle" Text="This session" FontSize="14" FontWeight="SemiBold"
                                   Margin="0,0,0,10" Foreground="{DynamicResource TextFillColorPrimaryBrush}" />
                        <ItemsControl x:Name="SideKeys" ItemTemplate="{StaticResource SideKeyRowTemplate}"
                                      Margin="0,0,0,10" />
                        <ItemsControl x:Name="Timeline" ItemTemplate="{StaticResource TimelineRowTemplate}" />
                        <TextBlock x:Name="TxtVerdict" FontSize="14" FontWeight="SemiBold" TextWrapping="Wrap"
                                   Margin="0,10,0,0"
                                   Foreground="{DynamicResource TextFillColorPrimaryBrush}" />
                    </StackPanel>
                </ScrollViewer>
            </Border>
        </Grid>

        <!-- Status bar -->
        <Grid Grid.Row="4" Margin="0,14,0,0">
            <Grid.ColumnDefinitions>
                <ColumnDefinition Width="*" />
                <ColumnDefinition Width="Auto" />
            </Grid.ColumnDefinitions>
            <TextBlock x:Name="TxtStatusLeft" Grid.Column="0" FontSize="12"
                       Foreground="{DynamicResource TextFillColorTertiaryBrush}" />
            <TextBlock x:Name="TxtStatusRight" Grid.Column="1" FontSize="12" HorizontalAlignment="Right"
                       Foreground="{DynamicResource TextFillColorTertiaryBrush}" />
        </Grid>

    </Grid>

        <!-- Apply tuning: second confirmation (flag 7) -->
        <Border x:Name="TuningConfirmDialog" Visibility="Collapsed"
                HorizontalAlignment="Stretch" VerticalAlignment="Stretch">
            <Border Style="{StaticResource CardBorderStyle}" MaxWidth="480"
                    HorizontalAlignment="Center" VerticalAlignment="Center" Padding="20">
                <StackPanel>
                    <TextBlock x:Name="TuningConfirmTitle" FontSize="16" FontWeight="SemiBold"
                               Text="Confirm tuning changes"
                               Foreground="{DynamicResource TextFillColorPrimaryBrush}" />
                    <TextBlock x:Name="TuningConfirmText" FontSize="13" TextWrapping="Wrap" Margin="0,10,0,0"
                               Text="Confirm the changes."
                               Foreground="{DynamicResource TextFillColorSecondaryBrush}" />
                    <StackPanel x:Name="TuningTickList" Visibility="Collapsed" Margin="0,4,0,0" />
                    <WrapPanel HorizontalAlignment="Right" Margin="0,16,0,0">
                        <Button x:Name="BtnTuningConfirmCancel" Content="Cancel" Margin="4,0"
                                AutomationProperties.Name="Cancel tuning changes" />
                        <Button x:Name="BtnTuningConfirmApply" Content="Apply" Margin="4,0"
                                ContentTemplate="{StaticResource ShieldContentTemplate}"
                                AutomationProperties.Name="Apply tuning changes"
                                Style="{DynamicResource AccentButtonStyle}" />
                    </WrapPanel>
                </StackPanel>
            </Border>
        </Border>

        <!-- v4.2 screens: First run, My PC, Gaps, Score, Share, About -->
        <Grid x:Name="ScreenFirstRun" Visibility="Collapsed">
            <Border Style="{StaticResource CardBorderStyle}" MaxWidth="640"
                    HorizontalAlignment="Center" VerticalAlignment="Center" Padding="20">
                <StackPanel>
                    <TextBlock x:Name="TxtFirstRunTitle" FontSize="18" FontWeight="SemiBold"
                               Foreground="{DynamicResource TextFillColorPrimaryBrush}" />
                    <TextBlock x:Name="TxtFirstRunChangesHeading" FontSize="13" FontWeight="SemiBold"
                               Margin="0,14,0,0" Foreground="{DynamicResource TextFillColorPrimaryBrush}" />
                    <TextBlock x:Name="TxtFirstRunChangesBody" FontSize="12" TextWrapping="Wrap"
                               Foreground="{DynamicResource TextFillColorSecondaryBrush}" />
                    <TextBlock x:Name="TxtFirstRunNeverHeading" FontSize="13" FontWeight="SemiBold"
                               Margin="0,14,0,0" Foreground="{DynamicResource TextFillColorPrimaryBrush}" />
                    <TextBlock x:Name="TxtFirstRunNeverBody" FontSize="12" TextWrapping="Wrap"
                               Foreground="{DynamicResource TextFillColorSecondaryBrush}" />
                    <TextBlock x:Name="TxtFirstRunSessionLabel" FontSize="12" Margin="0,14,0,0"
                               Foreground="{DynamicResource TextFillColorSecondaryBrush}" />
                    <TextBlock x:Name="TxtFirstRunSessionPath" FontSize="12" Style="{StaticResource MonoTextStyle}" />
                    <WrapPanel Margin="0,16,0,0">
                        <Button x:Name="BtnFirstRunChangeFolder" Margin="0,0,8,0" />
                        <Button x:Name="BtnFirstRunDryRun" Margin="0,0,8,0" />
                        <Button x:Name="BtnFirstRunGuide" Margin="0,0,8,0" />
                        <Button x:Name="BtnFirstRunContinue" Margin="0,0,8,0" Style="{DynamicResource AccentButtonStyle}" />
                    </WrapPanel>
                </StackPanel>
            </Border>
        </Grid>

        <Grid x:Name="ScreenMyPc" Visibility="Collapsed">
            <ScrollViewer VerticalScrollBarVisibility="Auto">
                <StackPanel Margin="16">
                    <TextBlock x:Name="TxtMyPcTitle" FontSize="18" FontWeight="SemiBold"
                               Foreground="{DynamicResource TextFillColorPrimaryBrush}" />
                    <TextBlock x:Name="TxtMyPcCpuTitle" FontSize="13" FontWeight="SemiBold" Margin="0,12,0,4"
                               Foreground="{DynamicResource TextFillColorPrimaryBrush}" />
                    <ItemsControl x:Name="MyPcCpuCard" ItemTemplate="{StaticResource CheckRowTemplate}" />
                    <TextBlock x:Name="TxtMyPcGpuTitle" FontSize="13" FontWeight="SemiBold" Margin="0,12,0,4"
                               Foreground="{DynamicResource TextFillColorPrimaryBrush}" />
                    <ItemsControl x:Name="MyPcGpuCard" ItemTemplate="{StaticResource CheckRowTemplate}" />
                    <TextBlock x:Name="TxtMyPcDisplayTitle" FontSize="13" FontWeight="SemiBold" Margin="0,12,0,4"
                               Foreground="{DynamicResource TextFillColorPrimaryBrush}" />
                    <ItemsControl x:Name="MyPcDisplayCard" ItemTemplate="{StaticResource CheckRowTemplate}" />
                    <Button x:Name="BtnConfirmDisplayLayout" HorizontalAlignment="Left" Margin="0,4,0,0" />
                    <TextBlock x:Name="TxtMyPcIracingTitle" FontSize="13" FontWeight="SemiBold" Margin="0,12,0,4"
                               Foreground="{DynamicResource TextFillColorPrimaryBrush}" />
                    <ItemsControl x:Name="MyPcIracingCard" ItemTemplate="{StaticResource CheckRowTemplate}" />
                    <TextBlock x:Name="TxtMyPcPeripheralsTitle" FontSize="13" FontWeight="SemiBold" Margin="0,12,0,4"
                               Foreground="{DynamicResource TextFillColorPrimaryBrush}" />
                    <ItemsControl x:Name="MyPcPeripheralsCard" ItemTemplate="{StaticResource CheckRowTemplate}" />
                    <TextBlock x:Name="TxtMyPcToolsTitle" FontSize="13" FontWeight="SemiBold" Margin="0,12,0,4"
                               Foreground="{DynamicResource TextFillColorPrimaryBrush}" />
                    <ItemsControl x:Name="ToolsList" ItemTemplate="{StaticResource ToolRowTemplate}" />
                    <Border x:Name="MyPcSessionSizeWarn" Style="{StaticResource CardBorderStyle}"
                            Visibility="Collapsed" Margin="0,12,0,0">
                        <StackPanel Orientation="Horizontal">
                            <TextBlock x:Name="TxtMyPcSessionSizeWarn" FontSize="12" VerticalAlignment="Center"
                                       Foreground="{DynamicResource TextFillColorPrimaryBrush}" />
                            <Button x:Name="BtnOpenSessionFolder" Margin="12,0,0,0" />
                        </StackPanel>
                    </Border>
                    <!-- The hard-fault trace. Its own card because it is the one
                         thing here that runs FOR a whole stint rather than once:
                         start it before you drive, stop it when you are done. -->
                    <Border Style="{StaticResource CardBorderStyle}" Margin="0,12,0,0">
                        <StackPanel>
                            <TextBlock x:Name="TxtHardFaultTraceTitle" FontWeight="SemiBold"
                                       Foreground="{DynamicResource TextFillColorPrimaryBrush}" />
                            <TextBlock x:Name="TxtHardFaultTraceState" FontSize="12" TextWrapping="Wrap" Margin="0,4,0,8"
                                       Foreground="{DynamicResource TextFillColorSecondaryBrush}" />
                            <Button x:Name="BtnHardFaultTrace" HorizontalAlignment="Left"
                                    ContentTemplate="{StaticResource ShieldContentTemplate}" />
                        </StackPanel>
                    </Border>
                </StackPanel>
            </ScrollViewer>
        </Grid>

        <Grid x:Name="ScreenGaps" Visibility="Collapsed">
            <DockPanel Margin="16">
                <TextBlock x:Name="TxtGapsTitle" DockPanel.Dock="Top" FontSize="18" FontWeight="SemiBold"
                           Foreground="{DynamicResource TextFillColorPrimaryBrush}" />
                <StackPanel DockPanel.Dock="Top" Orientation="Horizontal" Margin="0,10,0,10">
                    <TextBlock x:Name="TxtGapsFilterLabel" VerticalAlignment="Center" Margin="0,0,8,0"
                               Foreground="{DynamicResource TextFillColorSecondaryBrush}" />
                    <ComboBox x:Name="GapsFilterSeverity" Width="160" />
                    <Button x:Name="BtnExportGaps" Margin="16,0,0,0" />
                </StackPanel>
                <ItemsControl x:Name="GapsList" ItemTemplate="{StaticResource CheckRowTemplate}" />
            </DockPanel>
        </Grid>

        <Grid x:Name="ScreenScore" Visibility="Collapsed">
            <StackPanel Margin="16">
                <TextBlock x:Name="TxtScoreTitle" FontSize="18" FontWeight="SemiBold"
                           Foreground="{DynamicResource TextFillColorPrimaryBrush}" />
                <Grid Margin="0,12,0,0">
                    <Grid.ColumnDefinitions>
                        <ColumnDefinition Width="*" />
                        <ColumnDefinition Width="*" />
                    </Grid.ColumnDefinitions>
                    <StackPanel Grid.Column="0" Margin="0,0,8,0">
                        <TextBlock x:Name="TxtScoreBeforeTitle" FontSize="13" FontWeight="SemiBold"
                                   Foreground="{DynamicResource TextFillColorPrimaryBrush}" />
                        <ItemsControl x:Name="ScoreBeforeCard" ItemTemplate="{StaticResource CheckRowTemplate}" />
                        <Button x:Name="BtnCaptureBefore" Margin="0,8,0,0" HorizontalAlignment="Left" />
                    </StackPanel>
                    <StackPanel Grid.Column="1" Margin="8,0,0,0">
                        <TextBlock x:Name="TxtScoreAfterTitle" FontSize="13" FontWeight="SemiBold"
                                   Foreground="{DynamicResource TextFillColorPrimaryBrush}" />
                        <ItemsControl x:Name="ScoreAfterCard" ItemTemplate="{StaticResource CheckRowTemplate}" />
                        <Button x:Name="BtnCaptureAfter" Margin="0,8,0,0" HorizontalAlignment="Left" />
                    </StackPanel>
                </Grid>
                <TextBlock x:Name="TxtScoreLimits" FontSize="11" TextWrapping="Wrap" Margin="0,14,0,0"
                           Foreground="{DynamicResource TextFillColorSecondaryBrush}" />
            </StackPanel>
        </Grid>

        <Grid x:Name="ScreenShare" Visibility="Collapsed">
            <StackPanel Margin="16">
                <TextBlock x:Name="TxtShareTitle" FontSize="18" FontWeight="SemiBold"
                           Foreground="{DynamicResource TextFillColorPrimaryBrush}" />
                <TextBlock x:Name="TxtShareWhy" FontSize="12" TextWrapping="Wrap" Margin="0,6,0,0"
                           Foreground="{DynamicResource TextFillColorSecondaryBrush}" />
                <TextBlock x:Name="TxtSharePreviewLabel" FontSize="12" FontWeight="SemiBold" Margin="0,14,0,4"
                           Foreground="{DynamicResource TextFillColorPrimaryBrush}" />
                <Border Style="{StaticResource CardBorderStyle}" MaxHeight="240">
                    <ScrollViewer VerticalScrollBarVisibility="Auto">
                        <TextBlock x:Name="TxtSharePreview" Style="{StaticResource MonoTextStyle}" TextWrapping="Wrap" />
                    </ScrollViewer>
                </Border>
                <WrapPanel Margin="0,14,0,0">
                    <Button x:Name="BtnSaveReport" Margin="0,0,8,0" />
                    <Button x:Name="BtnOpenIssueForm" Margin="0,0,8,0" />
                    <Button x:Name="BtnDisableShare" Margin="0,0,8,0" />
                </WrapPanel>
            </StackPanel>
        </Grid>

        <Grid x:Name="ScreenAbout" Visibility="Collapsed">
            <StackPanel Margin="16" MaxWidth="480">
                <StackPanel Orientation="Horizontal">
                    <!-- Source is set in code, from the installed simrig.ico. A path
                         in the XAML would be relative to the process working folder,
                         which is not the install folder when a shortcut sets one. -->
                    <Image x:Name="AboutIcon" Width="40" Height="40" Margin="0,0,12,0"
                           VerticalAlignment="Center" RenderOptions.BitmapScalingMode="HighQuality" />
                    <TextBlock x:Name="TxtAboutTitle" FontSize="18" FontWeight="SemiBold"
                               VerticalAlignment="Center"
                               Foreground="{DynamicResource TextFillColorPrimaryBrush}" />
                </StackPanel>
                <StackPanel Orientation="Horizontal" Margin="0,12,0,0">
                    <TextBlock x:Name="TxtAboutVersionLabel" Foreground="{DynamicResource TextFillColorSecondaryBrush}" />
                    <TextBlock x:Name="TxtAboutVersion" Margin="6,0,0,0" Style="{StaticResource MonoTextStyle}" />
                </StackPanel>
                <StackPanel Orientation="Horizontal" Margin="0,4,0,0">
                    <TextBlock x:Name="TxtAboutCommitLabel" Foreground="{DynamicResource TextFillColorSecondaryBrush}" />
                    <TextBlock x:Name="TxtAboutCommit" Margin="6,0,0,0" Style="{StaticResource MonoTextStyle}" />
                </StackPanel>
                <StackPanel Orientation="Horizontal" Margin="0,4,0,0">
                    <TextBlock x:Name="TxtAboutHashLabel" Foreground="{DynamicResource TextFillColorSecondaryBrush}" />
                    <TextBlock x:Name="TxtAboutHash" Margin="6,0,0,0" Style="{StaticResource MonoTextStyle}" />
                </StackPanel>
                <TextBlock x:Name="TxtAboutUpdateStatus" FontSize="12" Margin="0,10,0,0"
                           Foreground="{DynamicResource TextFillColorSecondaryBrush}" />
                <TextBlock x:Name="TxtAboutCredits" FontSize="12" Margin="0,10,0,0"
                           Foreground="{DynamicResource TextFillColorSecondaryBrush}" />
                <WrapPanel Margin="0,14,0,0">
                    <Button x:Name="BtnCheckUpdate" Margin="0,0,8,0" />
                    <Button x:Name="BtnBuyMeACoffee" Margin="0,0,8,0" />
                    <Button x:Name="BtnUninstall" Margin="0,0,8,0" />
                </WrapPanel>
            </StackPanel>
        </Grid>

        <Border x:Name="UninstallDialog" Visibility="Collapsed"
                HorizontalAlignment="Stretch" VerticalAlignment="Stretch">
            <Border Style="{StaticResource CardBorderStyle}" MaxWidth="480"
                    HorizontalAlignment="Center" VerticalAlignment="Center" Padding="20">
                <StackPanel>
                    <TextBlock x:Name="TxtUninstallTitle" FontSize="16" FontWeight="SemiBold"
                               Foreground="{DynamicResource TextFillColorPrimaryBrush}" />
                    <TextBlock x:Name="TxtUninstallText" FontSize="13" TextWrapping="Wrap" Margin="0,10,0,0"
                               Foreground="{DynamicResource TextFillColorSecondaryBrush}" />
                    <WrapPanel HorizontalAlignment="Right" Margin="0,16,0,0">
                        <Button x:Name="BtnUninstallCancel" Margin="4,0" />
                        <Button x:Name="BtnUninstallConfirm" Margin="4,0" Style="{DynamicResource AccentButtonStyle}"
                                ContentTemplate="{StaticResource ShieldContentTemplate}" />
                    </WrapPanel>
                </StackPanel>
            </Border>
        </Border>
    </Grid>
</Window>
'@

# ---------------------------------------------------------------------------
# Button mode map (exposed for tests)
# ---------------------------------------------------------------------------

$script:ButtonModeMap = @{
    # The tuning buttons are in the three preflight modes only. They used to be
    # outside this map entirely, which meant they stayed visible in every mode -
    # the rig photos show Apply tuning, the brightest button on the screen, beside
    # End session while driving. The click was refused by the guards, so it was a
    # dead click on the loudest control (beta.1 review, section 7).
    Preflight   = @('BtnStart', 'BtnStartTools', 'BtnRecheck', 'BtnApplyTuning', 'BtnUndoTuning', 'BtnUndo', 'BtnDryRun', 'BtnOpenLog')
    NotReady    = @('BtnStartAnyway', 'BtnStartAnywayTools', 'BtnRecheck', 'BtnApplyTuning', 'BtnUndoTuning', 'BtnUndo', 'BtnDryRun', 'BtnOpenLog')
    NotReadyGpu = @('BtnFixGpu', 'BtnStartAnyway', 'BtnStartAnywayTools', 'BtnRecheck', 'BtnApplyTuning', 'BtnUndoTuning', 'BtnUndo', 'BtnDryRun', 'BtnOpenLog')
    Busy        = @()
    Watching    = @('BtnEndSession', 'BtnOpenLog')
    Restored    = @('BtnPush', 'BtnSaveLatencyMon', 'BtnOpenFolder', 'BtnOpenReport', 'BtnOpenLog')
    RestoredRed = @('BtnFix', 'BtnRestore', 'BtnUndo', 'BtnOpenLog')
    Pushed      = @('BtnSaveLatencyMon', 'BtnOpenFolder', 'BtnOpenReport', 'BtnOpenLog')
}

# One accent per mode: the button that is the thing to do next in that state.
# Fluent 2 allows one accent per surface, and the preflight strip had three at
# once (Start, Re-check, Apply tuning), which is the same as none - the eye has
# nothing to pick. Set at run time rather than in the XAML, because the same
# button is the answer in one mode and a secondary choice in another: Re-check is
# the accent in NotReady and a plain button in Preflight.
#
# A mode may have no accent. Busy shows no buttons at all.
$script:ButtonModeAccentMap = @{
    Preflight   = 'BtnStart'
    NotReady    = 'BtnRecheck'
    NotReadyGpu = 'BtnFixGpu'
    Busy        = ''
    Watching    = 'BtnEndSession'
    Restored    = 'BtnPush'
    RestoredRed = 'BtnFix'
    Pushed      = 'BtnOpenReport'
}

# All buttons that Show-ButtonSet knows about (union of every mode's list).
$script:AllButtonNames = @(
    'BtnDryRun', 'BtnStart', 'BtnStartTools', 'BtnStartAnyway', 'BtnStartAnywayTools', 'BtnFixGpu', 'BtnRecheck', 'BtnEndSession',
    'BtnRestore', 'BtnFix', 'BtnUndo', 'BtnPush', 'BtnSaveLatencyMon',
    'BtnOpenFolder', 'BtnOpenReport', 'BtnOpenLog',
    'BtnApplyTuning', 'BtnUndoTuning'
)

# v4.2 screens (exposed for tests) and every named element they add.
$script:ScreenNames = @('ScreenFirstRun', 'ScreenMyPc', 'ScreenGaps', 'ScreenScore', 'ScreenShare', 'ScreenAbout')

$script:V42ContractNames = @(
    'ScreenFirstRun', 'ScreenMyPc', 'ScreenGaps', 'ScreenScore', 'ScreenShare', 'ScreenAbout',
    'TxtFirstRunTitle', 'TxtFirstRunChangesHeading', 'TxtFirstRunChangesBody',
    'TxtFirstRunNeverHeading', 'TxtFirstRunNeverBody', 'TxtFirstRunSessionLabel', 'TxtFirstRunSessionPath',
    'BtnFirstRunChangeFolder', 'BtnFirstRunDryRun', 'BtnFirstRunGuide', 'BtnFirstRunContinue',
    'TxtMyPcTitle', 'TxtMyPcCpuTitle', 'MyPcCpuCard', 'TxtMyPcGpuTitle', 'MyPcGpuCard',
    'TxtMyPcDisplayTitle', 'MyPcDisplayCard', 'BtnConfirmDisplayLayout',
    'TxtMyPcIracingTitle', 'MyPcIracingCard', 'TxtMyPcPeripheralsTitle', 'MyPcPeripheralsCard',
    'TxtMyPcToolsTitle', 'ToolsList', 'MyPcSessionSizeWarn', 'TxtMyPcSessionSizeWarn', 'BtnOpenSessionFolder',
    'TxtHardFaultTraceTitle', 'TxtHardFaultTraceState', 'BtnHardFaultTrace',
    'TxtGapsTitle', 'TxtGapsFilterLabel', 'GapsFilterSeverity', 'BtnExportGaps', 'GapsList',
    'TxtScoreTitle', 'TxtScoreBeforeTitle', 'ScoreBeforeCard', 'BtnCaptureBefore',
    'TxtScoreAfterTitle', 'ScoreAfterCard', 'BtnCaptureAfter', 'TxtScoreLimits',
    'TxtShareTitle', 'TxtShareWhy', 'TxtSharePreviewLabel', 'TxtSharePreview',
    'BtnSaveReport', 'BtnOpenIssueForm', 'BtnDisableShare',
    'TxtAboutTitle', 'TxtAboutVersionLabel', 'TxtAboutVersion', 'TxtAboutCommitLabel', 'TxtAboutCommit',
    'TxtAboutHashLabel', 'TxtAboutHash', 'TxtAboutUpdateStatus', 'TxtAboutCredits',
    'BtnCheckUpdate', 'BtnBuyMeACoffee', 'BtnUninstall',
    'UninstallDialog', 'TxtUninstallTitle', 'TxtUninstallText', 'BtnUninstallCancel', 'BtnUninstallConfirm'
)

# Static text keys (requirement G-19): every element above whose text never
# changes at runtime maps to a key in SimRig.Strings.ps1. Dynamic values
# (row content, About's Version/Commit/Hash, the Share preview JSON) are
# set by their own Show-* functions from controller-supplied values, not
# from this map.
$script:V42StaticTextMap = @{
    # A TextBlock: its label goes through .Text. Putting it in the button map
    # instead set .Content on a TextBlock, which throws - and the console would
    # have thrown at startup on Windows, where Initialize-ScreenText runs for
    # real. Found by the screenshot render on the first Windows run.
    TxtHardFaultTraceTitle    = 'MyPc_HardFaultTitle'
    TxtFirstRunTitle          = 'FirstRun_Title'
    TxtFirstRunChangesHeading = 'FirstRun_ChangesHeading'
    TxtFirstRunChangesBody    = 'FirstRun_ChangesBody'
    TxtFirstRunNeverHeading   = 'FirstRun_NeverHeading'
    TxtFirstRunNeverBody      = 'FirstRun_NeverBody'
    TxtFirstRunSessionLabel   = 'FirstRun_SessionFolder'
    TxtMyPcTitle              = 'MyPc_Title'
    TxtMyPcCpuTitle           = 'MyPc_CpuCardTitle'
    TxtMyPcGpuTitle           = 'MyPc_GpuCardTitle'
    TxtMyPcDisplayTitle       = 'MyPc_DisplayCardTitle'
    TxtMyPcIracingTitle       = 'MyPc_IracingCardTitle'
    TxtMyPcPeripheralsTitle   = 'MyPc_PeripheralsTitle'
    TxtMyPcToolsTitle         = 'MyPc_ToolsCardTitle'
    TxtGapsTitle              = 'Gaps_Title'
    TxtGapsFilterLabel        = 'Gaps_FilterLabel'
    TxtScoreTitle             = 'Score_Title'
    TxtScoreBeforeTitle       = 'Score_BeforeTitle'
    TxtScoreAfterTitle        = 'Score_AfterTitle'
    TxtScoreLimits            = 'Score_Limits'
    TxtShareTitle             = 'Share_Title'
    TxtShareWhy               = 'Share_Why'
    TxtSharePreviewLabel      = 'Share_PreviewLabel'
    TxtAboutTitle             = 'About_Title'
    TxtAboutVersionLabel      = 'About_VersionLabel'
    TxtAboutCommitLabel       = 'About_CommitLabel'
    TxtAboutHashLabel         = 'About_HashLabel'
    TxtAboutCredits           = 'About_Credits'
    TxtUninstallTitle         = 'Uninstall_Title'
    TxtUninstallText          = 'Uninstall_Text'
}

# Buttons on the v4.2 screens: Content and AutomationProperties.Name both
# come from the same string key (G-19), set by Initialize-ScreenText.
# Non-button interactive controls on the v4.2 screens that need only an
# AutomationProperties.Name (G-19): element name -> string key.
$script:V42AutomationOnlyMap = @{
    GapsFilterSeverity = 'Gaps_FilterAutomationName'
}

$script:V42ButtonTextMap = @{
    BtnFirstRunChangeFolder = 'FirstRun_ChangeFolder'
    BtnFirstRunDryRun       = 'FirstRun_DryRun'
    BtnFirstRunGuide        = 'FirstRun_Guide'
    BtnFirstRunContinue     = 'FirstRun_Continue'
    BtnConfirmDisplayLayout = 'MyPc_ConfirmDisplayLabel'
    BtnOpenSessionFolder    = 'MyPc_OpenSessionFolder'
    BtnHardFaultTrace       = 'MyPc_HardFaultStart'
    BtnExportGaps           = 'Gaps_Export'
    BtnCaptureBefore        = 'Score_CaptureBefore'
    BtnCaptureAfter         = 'Score_CaptureAfter'
    BtnSaveReport           = 'Share_Save'
    BtnOpenIssueForm        = 'Share_OpenIssue'
    BtnDisableShare         = 'Share_Disable'
    BtnCheckUpdate          = 'About_CheckUpdate'
    BtnBuyMeACoffee         = 'About_BuyMeACoffee'
    BtnUninstallCancel      = 'Uninstall_Cancel'
    BtnUninstall            = 'Uninstall_Open'
    BtnUninstallConfirm     = 'Uninstall_Confirm'
}

# ---------------------------------------------------------------------------
# Apply tuning: row content (flag 7; CONTRACT.md view row shape)
# ---------------------------------------------------------------------------

# Fixed text for the four Apply tuning rows. Name/Detail/RestartText never
# change; the controller builds the full row (Name Detail Value Verdict,
# the same shape ConvertTo-PreflightViewRow uses) by adding Value as
# 'now -> new' from engine output, and Verdict 'Warn' when RestartNeeded
# is $true, 'Info' when it is $false (existing badge vocabulary - see
# BadgeBorderStyle above; this file adds no new Verdict values).
$script:TuningItems = @(
    [pscustomobject]@{
        Id            = 'GpuSteering'
        Name          = 'GPU interrupt steering'
        Detail        = 'Moves the graphics card interrupt to one CPU core.'
        RestartText   = 'Needs a restart. The screens go black for a few seconds.'
        RestartNeeded = $true
    }
    [pscustomobject]@{
        Id            = 'Mpo'
        Name          = 'MPO (Multiplane Overlay)'
        Detail        = 'A Windows display feature.'
        RestartText   = 'No restart needed.'
        RestartNeeded = $false
    }
    [pscustomobject]@{
        Id            = 'Hags'
        Name          = 'HAGS (Hardware-accelerated GPU scheduling)'
        # Text 15 of PUSH2-TEXTS-FOR-RICK-2026-10-03.md (Rick's "Yes"): HwSchMode 1 is off.
        Detail        = 'Turns hardware-accelerated GPU scheduling off.'
        RestartText   = 'Needs a restart.'
        RestartNeeded = $true
    }
    [pscustomobject]@{
        Id            = 'PowerPlan'
        Name          = 'Power plan'
        Detail        = 'The active Windows power plan.'
        RestartText   = 'No restart needed.'
        RestartNeeded = $false
    }
)

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

function Get-SimRigViewElement {
    <#
        .SYNOPSIS
        Looks up a named element in $script:View, or returns $null and logs
        a verbose message when the view has not been initialized or the
        name is missing.
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter(Mandatory)]
        [string]$Name
    )

    if (-not (Test-Path variable:script:View) -or $null -eq $script:View) {
        Write-Verbose "SimRigConsole.View: view not initialized, cannot resolve '$Name'."
        return $null
    }

    if (-not $script:View.ContainsKey($Name)) {
        Write-Verbose "SimRigConsole.View: no element named '$Name' in the view."
        return $null
    }

    return $script:View[$Name]
}

function Get-TuningItemInfo {
    <#
        .SYNOPSIS
        Returns the four Apply tuning rows' fixed text (Name, Detail,
        RestartText, RestartNeeded). Pure data, no engine or system
        calls: the controller adds Value ('now -> new') and Verdict from
        engine output.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param()

    return , @($script:TuningItems)
}

function Get-TuningRefusedDetail {
    <#
        .SYNOPSIS
        Returns the row Detail text for a tuning item whose write was
        refused because iRacing, a CapFrameX capture or OBS was running
        (flag 7).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('iRacing', 'A CapFrameX capture', 'OBS')]
        [string]$Reason
    )

    return "Refused. $Reason is running."
}

function Get-TuningRefusedBanner {
    <#
        .SYNOPSIS
        Returns the banner Title and Text for Apply tuning refused
        because iRacing, a CapFrameX capture or OBS is running (flag 7).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param()

    return [pscustomobject]@{
        Title = 'Cannot apply tuning now'
        Text  = 'iRacing, a CapFrameX capture, or OBS is running. Close it and try again.'
    }
}

# ---------------------------------------------------------------------------
# View functions
# ---------------------------------------------------------------------------

function Initialize-ConsoleView {
    <#
        .SYNOPSIS
        Parses the console XAML, resolves every named element and creates
        the three bound collections. Returns the Window.
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter(Mandatory)]
        [string]$Xaml
    )

    Add-Type -AssemblyName PresentationFramework
    Add-Type -AssemblyName PresentationCore
    Add-Type -AssemblyName WindowsBase
    Add-Type -AssemblyName UIAutomationTypes

    $window = [System.Windows.Markup.XamlReader]::Parse($Xaml)

    $names = @(
        'TxtTitle', 'TxtSubtitle', 'TxtRig', 'TxtSession',
        'Step1', 'Step2', 'Step3', 'Step4', 'Step5',
        'StepText1', 'StepText2', 'StepText3', 'StepText4', 'StepText5',
        'Banner', 'BannerIcon', 'BannerTitle', 'BannerText',
        'BtnDryRun', 'BtnStart', 'BtnStartTools', 'BtnStartAnyway', 'BtnStartAnywayTools', 'BtnFixGpu', 'BtnRecheck',
        'BtnEndSession', 'BtnRestore', 'BtnFix', 'BtnUndo',
        'BtnPush', 'BtnSaveLatencyMon', 'BtnOpenFolder', 'BtnOpenReport', 'BtnOpenLog',
        'BtnApplyTuning', 'BtnUndoTuning',
        'TuningConfirmDialog', 'TuningConfirmTitle', 'TuningConfirmText', 'TuningTickList',
        'BtnTuningConfirmApply', 'BtnTuningConfirmCancel',
        'ListLeftTitle', 'CheckList', 'ListRightTitle', 'Timeline', 'SideKeys',
        'TxtVerdict', 'TxtStatusLeft', 'TxtStatusRight', 'AboutIcon'
    ) + $script:V42ContractNames

    $view = @{}
    foreach ($name in $names) {
        $element = $window.FindName($name)
        if ($null -eq $element) {
            Write-Verbose "Initialize-ConsoleView: XAML is missing named element '$name'."
            continue
        }
        $view[$name] = $element
    }
    $script:View = $view

    $script:CheckRows = [System.Collections.ObjectModel.ObservableCollection[object]]::new()
    $script:TimelineRows = [System.Collections.ObjectModel.ObservableCollection[object]]::new()
    $script:SideRows = [System.Collections.ObjectModel.ObservableCollection[object]]::new()

    $checkList = Get-SimRigViewElement -Name 'CheckList'
    if ($null -ne $checkList) { $checkList.ItemsSource = $script:CheckRows }

    $timeline = Get-SimRigViewElement -Name 'Timeline'
    if ($null -ne $timeline) { $timeline.ItemsSource = $script:TimelineRows }

    $sideKeys = Get-SimRigViewElement -Name 'SideKeys'
    if ($null -ne $sideKeys) { $sideKeys.ItemsSource = $script:SideRows }

    Initialize-ScreenText
    Initialize-ViewIcon -Window $window

    return $window
}

function Initialize-ViewIcon {
    <#
        .SYNOPSIS
        Puts the app icon on the window - so the taskbar and Alt+Tab show the road
        rather than the PowerShell logo - and on the About screen.

        .DESCRIPTION
        Both shortcuts start pwsh.exe, so without this the running window is a
        PowerShell window as far as Windows is concerned, whatever the shortcut's
        own icon says. The .lnk icon only fixes the desktop.

        Named Initialize-, not Set-: the view's verb contract allows Initialize,
        Show, Hide, Add, Invoke and Get, and it exists to stop this file turning
        into something that writes. Putting an icon on a window it just built is
        part of building it.

        Best effort by design. A missing or unreadable icon file is a cosmetic
        problem, and the console opening is not negotiable: the catch logs and
        carries on. The file sits beside this script, so the path comes from
        $PSScriptRoot rather than the working folder, which a shortcut can set to
        anywhere.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Window)

    try {
        $iconPath = Join-Path -Path $PSScriptRoot -ChildPath 'simrig.ico'
        if (-not (Test-Path -LiteralPath $iconPath)) { return }
        $uri = [System.Uri]::new($iconPath)
        $decoder = [System.Windows.Media.Imaging.BitmapDecoder]::Create(
            $uri,
            [System.Windows.Media.Imaging.BitmapCreateOptions]::None,
            [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad)

        # 32 for the window: Windows reuses this one image for the title bar and
        # for the taskbar and Alt+Tab card, so it is one compromise either way.
        # The taskbar and Alt+Tab are bigger and looked at more, and our 32 frame
        # downscales to 16 better than the 256 frame does.
        $Window.Icon = Get-ViewIconFrame -Decoder $decoder -Size 32

        $aboutIcon = Get-SimRigViewElement -Name 'AboutIcon'
        if ($null -ne $aboutIcon) {
            # The About image is 40 px, so 48 down rather than 32 up.
            $aboutIcon.Source = Get-ViewIconFrame -Decoder $decoder -Size 48
        }
    }
    catch {
        Write-Verbose ('Initialize-ViewIcon: {0}' -f $_.Exception.Message)
    }
}

function Get-ViewIconFrame {
    <#
        .SYNOPSIS
        Picks the frame of a multi-frame .ico that suits a given display size.

        .DESCRIPTION
        BitmapFrame::Create on an .ico URI returns the FIRST frame in the file,
        not the best one. Ours are written smallest first, so every caller was
        silently getting the 16 px frame - and the About screen was showing a
        16 px drawing blown up to 40, which is why it looked like a smudge with
        a red arrow in it while the 48 px frame sitting in the same file was
        fine. Nothing reported an error; it just looked wrong.

        Prefers the smallest frame at or above the wanted size, because scaling
        a drawing down keeps more of it than scaling one up. Falls back to the
        largest frame when nothing is big enough.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Decoder,
        [Parameter(Mandatory)] [int] $Size
    )

    $frames = @($Decoder.Frames)
    if ($frames.Count -eq 0) { return $null }
    $atOrAbove = @($frames | Where-Object { $_.PixelWidth -ge $Size } | Sort-Object -Property PixelWidth)
    if ($atOrAbove.Count -gt 0) { return $atOrAbove[0] }
    return @($frames | Sort-Object -Property PixelWidth)[-1]
}

function Show-Heading {
    <#
        .SYNOPSIS
        Sets the screen heading and sub line.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Title,

        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Subtitle
    )

    $titleElement = Get-SimRigViewElement -Name 'TxtTitle'
    if ($null -ne $titleElement) { $titleElement.Text = $Title }

    $subtitleElement = Get-SimRigViewElement -Name 'TxtSubtitle'
    if ($null -ne $subtitleElement) { $subtitleElement.Text = $Subtitle }
}

function Show-HeaderMeta {
    <#
        .SYNOPSIS
        Sets the header meta lines: rig name and session label.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Rig,

        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Session
    )

    $rigElement = Get-SimRigViewElement -Name 'TxtRig'
    if ($null -ne $rigElement) { $rigElement.Text = $Rig }

    $sessionElement = Get-SimRigViewElement -Name 'TxtSession'
    if ($null -ne $sessionElement) { $sessionElement.Text = $Session }
}

function Show-StepState {
    <#
        .SYNOPSIS
        Sets the state word and colours for one stepper cell.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateRange(1, 5)]
        [int]$Step,

        [Parameter(Mandatory)]
        [ValidateSet('Waiting', 'Current', 'Done', 'Failed')]
        [string]$State,

        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Text
    )

    $cell = Get-SimRigViewElement -Name "Step$Step"
    $textElement = Get-SimRigViewElement -Name "StepText$Step"

    if ($null -ne $textElement) {
        $textElement.Text = $Text
    }

    if ($null -eq $cell) {
        return
    }

    $barBrushKey = switch ($State) {
        'Done' { 'SystemFillColorSuccessBrush' }
        'Current' { 'AccentFillColorDefaultBrush' }
        'Failed' { 'SystemFillColorCriticalBrush' }
        default { 'ControlStrokeColorDefaultBrush' }
    }

    $barBrush = $cell.TryFindResource($barBrushKey)
    $grid = $cell.Child
    if ($null -ne $grid -and $grid.Children.Count -ge 2) {
        $bar = $grid.Children[1]
        if ($null -ne $barBrush) { $bar.Background = $barBrush }
    }

    if ($State -eq 'Current') {
        $cardBrush = $cell.TryFindResource('CardBackgroundFillColorDefaultBrush')
        if ($null -ne $cardBrush) { $cell.Background = $cardBrush }
    }
    else {
        $cell.Background = $null
    }
}

function Show-Banner {
    <#
        .SYNOPSIS
        Sets the InfoBar-style banner: background, icon glyph and text.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Ok', 'Bad', 'Warn', 'Info')]
        [string]$Kind,

        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Title,

        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Text
    )

    $banner = Get-SimRigViewElement -Name 'Banner'
    $iconElement = Get-SimRigViewElement -Name 'BannerIcon'
    $titleElement = Get-SimRigViewElement -Name 'BannerTitle'
    $textElement = Get-SimRigViewElement -Name 'BannerText'

    if ($null -ne $titleElement) { $titleElement.Text = $Title }
    if ($null -ne $textElement) { $textElement.Text = $Text }

    $glyph = switch ($Kind) {
        'Ok' { [char]0x2713 }
        'Bad' { '!' }
        'Warn' { '!' }
        default { 'i' }
    }
    if ($null -ne $iconElement) { $iconElement.Text = $glyph }

    if ($null -eq $banner) {
        return
    }

    $brushKey = switch ($Kind) {
        'Ok' { 'SystemFillColorSuccessBackgroundBrush' }
        'Bad' { 'SystemFillColorCriticalBackgroundBrush' }
        'Warn' { 'SystemFillColorCautionBackgroundBrush' }
        default { 'SystemFillColorAttentionBackgroundBrush' }
    }

    $brush = $banner.TryFindResource($brushKey)
    if ($null -ne $brush) { $banner.Background = $brush }
}

function Show-CheckRow {
    <#
        .SYNOPSIS
        Replaces the left check/restore list with the given rows and sets
        the left group title.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$Row,

        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Title
    )

    $titleElement = Get-SimRigViewElement -Name 'ListLeftTitle'
    if ($null -ne $titleElement) { $titleElement.Text = $Title }

    if (-not (Test-Path variable:script:CheckRows) -or $null -eq $script:CheckRows) {
        Write-Verbose 'Show-CheckRow: view not initialized, nothing to update.'
        return
    }

    $script:CheckRows.Clear()
    foreach ($item in $Row) {
        $script:CheckRows.Add($item)
    }
}

function Add-TimelineEntry {
    <#
        .SYNOPSIS
        Appends one entry to the timeline, keeping the last 500.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Time,

        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Message,

        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Severity
    )

    if (-not (Test-Path variable:script:TimelineRows) -or $null -eq $script:TimelineRows) {
        Write-Verbose 'Add-TimelineEntry: view not initialized, nothing to update.'
        return
    }

    $entry = [pscustomobject]@{
        Time     = $Time
        Message  = $Message
        Severity = $Severity
    }
    $script:TimelineRows.Add($entry)

    while ($script:TimelineRows.Count -gt 500) {
        $script:TimelineRows.RemoveAt(0)
    }
}

function Show-SideKey {
    <#
        .SYNOPSIS
        Replaces the right panel's key/value rows and sets its title.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$Row,

        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Title
    )

    $titleElement = Get-SimRigViewElement -Name 'ListRightTitle'
    if ($null -ne $titleElement) { $titleElement.Text = $Title }

    if (-not (Test-Path variable:script:SideRows) -or $null -eq $script:SideRows) {
        Write-Verbose 'Show-SideKey: view not initialized, nothing to update.'
        return
    }

    $script:SideRows.Clear()
    foreach ($item in $Row) {
        $script:SideRows.Add($item)
    }
}

function Show-Verdict {
    <#
        .SYNOPSIS
        Sets the one-line restore verdict. $Green $null hides it, $true
        colours it success, $false colours it critical.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Text,

        [Parameter(Mandatory)]
        [AllowNull()]
        [Nullable[bool]]$Green
    )

    $textElement = Get-SimRigViewElement -Name 'TxtVerdict'
    if ($null -eq $textElement) {
        return
    }

    if ($null -eq $Green) {
        $textElement.Text = ''
        $textElement.Visibility = [System.Windows.Visibility]::Collapsed
        return
    }

    $textElement.Text = $Text
    $textElement.Visibility = [System.Windows.Visibility]::Visible

    $brushKey = if ($Green) { 'SystemFillColorSuccessBrush' } else { 'SystemFillColorCriticalBrush' }
    $brush = $textElement.TryFindResource($brushKey)
    if ($null -ne $brush) { $textElement.Foreground = $brush }
}

function Show-StatusBar {
    <#
        .SYNOPSIS
        Sets the status bar's left and right text.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Left,

        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Right
    )

    $leftElement = Get-SimRigViewElement -Name 'TxtStatusLeft'
    if ($null -ne $leftElement) { $leftElement.Text = $Left }

    $rightElement = Get-SimRigViewElement -Name 'TxtStatusRight'
    if ($null -ne $rightElement) { $rightElement.Text = $Right }
}

# The buttons that write the values of known-good.psd1. They are shown only where
# the selected profile has the key Values.TuningFromKnownGood (blocker 4, push 1 of
# the unit tune).
$script:TuningButtonNames = @('BtnFixGpu', 'BtnApplyTuning', 'BtnUndoTuning')

function Get-SimRigTuningAllowed {
    <#
        .SYNOPSIS
        The rule of the window: true only when the console set $script:TuningAllowed to
        $true. A rule that is not set is "not allowed" (the safe direction), not an error.

        .DESCRIPTION
        One place for the read, for Show-ButtonSet and the automatic steering fix (Cowork,
        after the REVIEW at 6125ee8). The view and the console run in strict mode, where a
        plain read of a variable that is not set throws, and the screenshot tool and the
        self-test load the view and do not set it (the workflow screens, run 37118149997).
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param()
    # Only the boolean $true. With -eq $true the number 1 and the text 'true' were allowed
    # also (REVIEW at 564807b, M6).
    $value = Get-Variable -Name TuningAllowed -Scope Script -ValueOnly -ErrorAction SilentlyContinue
    return ($value -is [bool] -and $value)
}

function Get-SimRigViewFlag {
    <#
        .SYNOPSIS
        Push 2 of the unit tune, step 7b: true only when the console set the script variable of
        this name to the boolean $true. A variable that is not set is false (the safe direction),
        as in Get-SimRigTuningAllowed.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)] [ValidateSet('TuningOffered', 'TuningMarkerPresent')] [string] $Name)
    $value = Get-Variable -Name $Name -Scope Script -ValueOnly -ErrorAction SilentlyContinue
    return ($value -is [bool] -and $value)
}

function Get-ButtonSetName {
    <#
        .SYNOPSIS
        The buttons of a mode and its accent, with the tuning buttons left out when
        tuning is not allowed on this PC. Pure, so the rule is testable without a
        window.

        .DESCRIPTION
        On a PC that is not the rig, NotReadyGpu is NotReady: its accent is Fix GPU
        steering, a button that is not shown there. The elevated step refuses the
        three operations also, so this is not the only guard.

        Push 2 of the unit tune, step 7b: TuningAllowed (the rig) decides Fix GPU steering.
        TuningOffered (the rig or a supported PC) decides Apply tuning. UndoOffered decides Undo
        tuning: the console gives it also when the marker is there, because a way back does not
        depend on the check that allowed the write (design section 6). Each one that is not given
        is the value of the one before it, so a call with TuningAllowed only is as before.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Preflight', 'NotReady', 'NotReadyGpu', 'Busy', 'Watching', 'Restored', 'RestoredRed', 'Pushed')]
        [string] $Mode,
        [Parameter(Mandatory)] [bool] $TuningAllowed,
        [bool] $TuningOffered,
        [bool] $UndoOffered
    )

    $offered = if ($PSBoundParameters.ContainsKey('TuningOffered')) { $TuningOffered } else { $TuningAllowed }
    $undo = if ($PSBoundParameters.ContainsKey('UndoOffered')) { $UndoOffered } else { $offered }
    $effective = if (-not $TuningAllowed -and $Mode -eq 'NotReadyGpu') { 'NotReady' } else { $Mode }
    $names = @($script:ButtonModeMap[$effective])
    if (-not $TuningAllowed) { $names = @($names | Where-Object { $_ -ne 'BtnFixGpu' }) }
    if (-not $offered) { $names = @($names | Where-Object { $_ -ne 'BtnApplyTuning' }) }
    if (-not $undo) { $names = @($names | Where-Object { $_ -ne 'BtnUndoTuning' }) }
    return [pscustomobject]@{ Mode = $effective; Name = $names; Accent = (Get-ButtonModeAccent -Mode $effective) }
}

function Show-ButtonSet {
    <#
        .SYNOPSIS
        Shows only the buttons that belong to the given mode; collapses
        every other known button.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Preflight', 'NotReady', 'NotReadyGpu', 'Busy', 'Watching', 'Restored', 'RestoredRed', 'Pushed')]
        [string]$Mode
    )

    # The rule is set by the console from the selected profile. When it is not set, no
    # tuning button is shown: the safe direction (Get-SimRigTuningAllowed).
    # Step 7b: the same safe read for the two values of a supported PC and of the marker.
    $offered = Get-SimRigViewFlag -Name TuningOffered
    $set = Get-ButtonSetName -Mode $Mode -TuningAllowed (Get-SimRigTuningAllowed) -TuningOffered $offered `
        -UndoOffered ($offered -or (Get-SimRigViewFlag -Name TuningMarkerPresent))
    $visibleNames = $set.Name
    $accentName = Get-ButtonModeAccent -Mode $set.Mode
    $accentStyle = $null
    if ($accentName) {
        $window = Get-SimRigViewElement -Name 'TxtTitle'
        if ($null -ne $window) { $accentStyle = $window.TryFindResource('AccentButtonStyle') }
    }

    foreach ($name in $script:AllButtonNames) {
        $button = Get-SimRigViewElement -Name $name
        if ($null -eq $button) {
            continue
        }
        if ($visibleNames -contains $name) {
            $button.Visibility = [System.Windows.Visibility]::Visible
        }
        else {
            $button.Visibility = [System.Windows.Visibility]::Collapsed
        }
        # $null puts the button back on the theme's implicit style. Set every time
        # rather than only on the accent button: a mode change has to take the accent
        # off the last mode's button, or two of them glow.
        $button.Style = if ($name -eq $accentName) { $accentStyle } else { $null }
    }
}

function Get-ButtonModeAccent {
    <#
        .SYNOPSIS
        The one button that carries the accent in this mode, or '' for none. Pure,
        so the rule is testable without a window.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Preflight', 'NotReady', 'NotReadyGpu', 'Busy', 'Watching', 'Restored', 'RestoredRed', 'Pushed')]
        [string] $Mode
    )

    return [string]$script:ButtonModeAccentMap[$Mode]
}

function Get-TuningConfirmMessage {
    <#
        .SYNOPSIS
        The second-confirmation dialog's title and body, composed from the facts
        Get-TuningConfirmView returns and the text in SimRig.Strings.ps1
        (A-FIX-02, G-19).

        .DESCRIPTION
        Every sentence comes from a string key, so the app can be translated by
        replacing one file. The restart sentence appears only when the plan holds
        an item that needs one: a warning that is always shown stops being read,
        and the whole point of asking twice is that the second ask says something
        the first one did not.

        Touches no UI element, so it can be tested on Linux.

        Push 2 of the unit tune, step 7b: the second ask lists only the ticked items, one line each
        with the value now and the new value (texts 3 or 4, then text 5 for each), then text 33 when
        HAGS is ticked, text 8 when an item needs a restart, texts 9 or 10 for the items with an
        accepted value, text 6, and text 7 when GPU steering is ticked (the rig only). PlanName is the
        name of the active power plan (the reading of powercfg), for text 28.

        .OUTPUTS
        [pscustomobject] Title, Text.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)] $View, [AllowNull()] [string] $PlanName)

    $lines = [System.Collections.Generic.List[string]]::new()
    if ([int]$View.ChangeCount -eq 1) { $lines.Add((Get-SimRigString -Key 'Tuning_ConfirmOne')) }
    else { $lines.Add(((Get-SimRigString -Key 'Tuning_ConfirmMany') -f [int]$View.ChangeCount)) }
    foreach ($item in @($View.ChangeItem)) {
        $lines.Add(((Get-SimRigString -Key 'Tuning_ConfirmItem') -f [string]$item.Name,
                (Get-TuningValueText -Id ([string]$item.Id) -Value $item.Now -PlanName $PlanName),
                (Get-TuningValueText -Id ([string]$item.Id) -Value $item.Target)))
    }

    $parts = [System.Collections.Generic.List[string]]::new()
    if ($View.HagsTicked) { $parts.Add((Get-SimRigString -Key 'Tuning_DetailHags')) }
    if ($View.RestartNeeded) {
        $parts.Add((Get-SimRigString -Key 'Tuning_ConfirmRestart') -f (@($View.RestartName) -join ', '))
    }
    if ([int]$View.SkipCount -eq 1) {
        $parts.Add((Get-SimRigString -Key 'Tuning_ConfirmSkipOne'))
    }
    elseif ([int]$View.SkipCount -gt 1) {
        $parts.Add((Get-SimRigString -Key 'Tuning_ConfirmSkipMany') -f [int]$View.SkipCount)
    }
    $parts.Add((Get-SimRigString -Key 'Tuning_ConfirmUndo'))
    if ($View.SteeringTicked) { $parts.Add((Get-SimRigString -Key 'Tuning_ConfirmNoUndoSteering')) }
    $lines.Add('')
    $lines.Add(($parts -join ' '))

    return [pscustomobject]@{
        Title = (Get-SimRigString -Key 'Tuning_ConfirmTitle')
        Text  = ($lines -join "`n")
    }
}

function Get-TuningValueText {
    <#
        .SYNOPSIS
        Push 2 of the unit tune, step 7b, text 28: a tuning value in words, with the number beside
        the word so that a person can compare it with the registry. MPO (OverlayTestMode): not set
        is on, 5 is off. HAGS (HwSchMode): not set is "Windows decides", 1 is off, 2 is on. The power
        plan: "{name} ({GUID})", with the name of the plan that powercfg reads for the value now, and
        "Windows Balanced" for its GUID. Each other value is shown as it is. Pure.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)] [string] $Id, [AllowNull()] $Value, [AllowNull()] [string] $PlanName)

    $text = if ($null -eq $Value) { $null } else { [string]$Value }
    switch ($Id) {
        'Mpo' {
            if ($null -eq $text) { return (Get-SimRigString -Key 'Tuning_ValueMpoNotSet') }
            if ($text -eq '5') { return ((Get-SimRigString -Key 'Tuning_ValueOff') -f $text) }
        }
        'Hags' {
            if ($null -eq $text) { return (Get-SimRigString -Key 'Tuning_ValueHagsNotSet') }
            if ($text -eq '1') { return ((Get-SimRigString -Key 'Tuning_ValueOff') -f $text) }
            if ($text -eq '2') { return ((Get-SimRigString -Key 'Tuning_ValueOn') -f $text) }
        }
        'PowerPlan' {
            if ($null -eq $text) { return 'not set' }
            if (-not [string]::IsNullOrWhiteSpace($PlanName)) { return ((Get-SimRigString -Key 'Tuning_ValuePlan') -f $PlanName, $text) }
            if ($text -eq '381b4222-f694-41f0-9685-ff5bb260df2e') { return ((Get-SimRigString -Key 'Tuning_ValuePlan') -f (Get-SimRigString -Key 'Tuning_PlanBalanced'), $text) }
        }
    }
    if ($null -eq $text) { return 'not set' }
    return $text
}

function Get-TuningTickRow {
    <#
        .SYNOPSIS
        Push 2 of the unit tune, step 7b, the first ask (design section 4, texts 26 to 33, the Cowork
        note of the layout of 7b, point 1): one row for each item of the offer. An item with Offer
        Write has a tick box (CanTick), the value now and the new value (text 27), and the text of
        its item: MPO text 31, HAGS text 33, the power plan text 32 on a supported PC. On the rig the
        power plan and GPU steering keep the fixed text of $script:TuningItems, because the rig
        writes the values of known-good.psd1 there and text 32 names one case of a supported PC.
        An item with Offer NoChange has no tick box and text 30. No row is ticked. Pure.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [AllowNull()] [AllowEmptyCollection()] [object[]] $Offer,
        [AllowNull()] [string] $State,
        [AllowNull()] [string] $PlanName
    )

    $fixed = @{}
    foreach ($info in @($script:TuningItems)) { $fixed[[string]$info.Id] = [string]$info.Detail }
    $rows = foreach ($item in @(@($Offer) | Where-Object { $null -ne $_ })) {
        $id = [string]$item.Id
        $now = Get-TuningValueText -Id $id -Value $item.Now -PlanName $PlanName
        if ([string](Get-KnownGoodField -Entry $item -Name 'Offer') -eq 'Write') {
            $detail = switch ($id) {
                'Mpo' { Get-SimRigString -Key 'Tuning_DetailMpo' }
                'Hags' { Get-SimRigString -Key 'Tuning_DetailHags' }
                'PowerPlan' { if ($State -eq 'Rig') { $fixed['PowerPlan'] } else { Get-SimRigString -Key 'Tuning_DetailPlan' } }
                default { $fixed[$id] }
            }
            [pscustomobject]@{
                Id = $id; Name = [string]$item.Name; CanTick = $true
                Value = ((Get-SimRigString -Key 'Tuning_TickValue') -f $now, (Get-TuningValueText -Id $id -Value $item.Target))
                Detail = [string]$detail
            }
        }
        else {
            [pscustomobject]@{
                Id = $id; Name = [string]$item.Name; CanTick = $false; Value = $now
                Detail = ((Get-SimRigString -Key 'Tuning_NoChange') -f $now)
            }
        }
    }
    return , @($rows)
}

function Show-TuningConfirm {
    <#
        .SYNOPSIS
        Shows or hides the second-confirmation dialog for Apply tuning
        (flag 7). It writes -Title and -Text into the dialog when they are
        given (text 23 names the title of the Fix GPU ask), and sets its
        visibility.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [bool]$Visible,

        # The controller composes these from Get-TuningConfirmView and
        # SimRig.Strings.ps1. Left out, the dialog keeps whatever it last said -
        # which is what a Hide call wants.
        [AllowNull()] [string]$Title,
        [AllowNull()] [string]$Text,

        # Push 2 of the unit tune, step 7b: the rows of the first ask (Get-TuningTickRow). With
        # rows, the dialog shows the tick list and Apply is not active until a box is ticked. With
        # none (the second ask, the Fix GPU ask, a hide), the list is empty and Apply is active.
        [AllowNull()] [AllowEmptyCollection()] [object[]]$TickRow
    )

    # The tick list and the rule of Apply first: they need no WPF type when there is no row, so the
    # rule is testable without a window.
    $list = Get-SimRigViewElement -Name 'TuningTickList'
    $apply = Get-SimRigViewElement -Name 'BtnTuningConfirmApply'
    $rows = @(@($TickRow) | Where-Object { $null -ne $_ })
    if ($null -ne $list) {
        $list.Children.Clear()
        foreach ($row in $rows) {
            $panel = [System.Windows.Controls.StackPanel]::new()
            $panel.Margin = [System.Windows.Thickness]::new(0, 8, 0, 0)
            if ($row.CanTick) {
                $box = [System.Windows.Controls.CheckBox]::new()
                $box.Content = [string]$row.Name
                $box.Tag = [string]$row.Id
                $box.IsChecked = $false
                [System.Windows.Automation.AutomationProperties]::SetName($box, [string]$row.Name)
                $box.Add_Click({ Invoke-TuningTickApply })
                [void]$panel.Children.Add($box)
            }
            else {
                $name = [System.Windows.Controls.TextBlock]::new()
                $name.Text = [string]$row.Name
                $name.FontWeight = [System.Windows.FontWeights]::SemiBold
                [void]$panel.Children.Add($name)
            }
            foreach ($line in @([string]$row.Value, [string]$row.Detail)) {
                $block = [System.Windows.Controls.TextBlock]::new()
                $block.Text = $line
                $block.TextWrapping = [System.Windows.TextWrapping]::Wrap
                $block.Margin = [System.Windows.Thickness]::new(24, 2, 0, 0)
                [void]$panel.Children.Add($block)
            }
            [void]$list.Children.Add($panel)
        }
        $list.Visibility = if ($rows.Count -gt 0) { [System.Windows.Visibility]::Visible } else { [System.Windows.Visibility]::Collapsed }
    }
    if ($null -ne $apply) { $apply.IsEnabled = ($rows.Count -eq 0) }

    $dialog = Get-SimRigViewElement -Name 'TuningConfirmDialog'
    if ($null -eq $dialog) {
        return
    }

    if ($PSBoundParameters.ContainsKey('Title') -and -not [string]::IsNullOrWhiteSpace($Title)) {
        $titleBlock = Get-SimRigViewElement -Name 'TuningConfirmTitle'
        if ($null -ne $titleBlock) { $titleBlock.Text = $Title }
    }
    if ($PSBoundParameters.ContainsKey('Text') -and -not [string]::IsNullOrWhiteSpace($Text)) {
        $textBlock = Get-SimRigViewElement -Name 'TuningConfirmText'
        if ($null -ne $textBlock) { $textBlock.Text = $Text }
    }

    $dialog.Visibility = if ($Visible) {
        [System.Windows.Visibility]::Visible
    }
    else {
        [System.Windows.Visibility]::Collapsed
    }
}

function Get-TuningTickedId {
    <#
        .SYNOPSIS
        Push 2 of the unit tune, step 7b: the ids of the boxes of the tick list that are ticked, in
        the order of the list.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param()
    $list = Get-SimRigViewElement -Name 'TuningTickList'
    if ($null -eq $list) { return , @() }
    $ids = foreach ($panel in @($list.Children)) {
        foreach ($child in @($panel.Children)) {
            if ($child -is [System.Windows.Controls.CheckBox] -and $child.IsChecked -eq $true) { [string]$child.Tag }
        }
    }
    return , @($ids)
}

function Invoke-TuningTickApply {
    <#
        .SYNOPSIS
        Push 2 of the unit tune, step 7b (the Cowork note of the layout, point 2): Apply of the first
        ask is active only while at least one box is ticked.
    #>
    [CmdletBinding()]
    param()
    $apply = Get-SimRigViewElement -Name 'BtnTuningConfirmApply'
    # Assign, then wrap: the function returns the comma form.
    $ids = Get-TuningTickedId
    if ($null -ne $apply) { $apply.IsEnabled = (@($ids).Count -gt 0) }
}

function Show-TuningButtonSet {
    <#
        .SYNOPSIS
        Shows or hides the Apply tuning and Undo tuning buttons. Kept
        apart from Show-ButtonSet: the tuning buttons are not part of
        the five-step pipeline's button modes.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [bool]$CanApply,

        [Parameter(Mandatory)]
        [bool]$CanUndo
    )

    $applyButton = Get-SimRigViewElement -Name 'BtnApplyTuning'
    if ($null -ne $applyButton) {
        $applyButton.Visibility = if ($CanApply) {
            [System.Windows.Visibility]::Visible
        }
        else {
            [System.Windows.Visibility]::Collapsed
        }
    }

    $undoButton = Get-SimRigViewElement -Name 'BtnUndoTuning'
    if ($null -ne $undoButton) {
        $undoButton.Visibility = if ($CanUndo) {
            [System.Windows.Visibility]::Visible
        }
        else {
            [System.Windows.Visibility]::Collapsed
        }
    }
}

function Invoke-OnUiThread {
    <#
        .SYNOPSIS
        Runs the given scriptblock on the window's UI thread via
        Dispatcher.Invoke. Used by timer callbacks (e.g. the 15 s watch
        poll) that run off the UI thread.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [scriptblock]$Action
    )

    $window = Get-SimRigViewElement -Name 'TxtTitle'
    if ($null -eq $window -or $null -eq $window.Dispatcher) {
        Write-Verbose 'Invoke-OnUiThread: no dispatcher available, running inline.'
        & $Action
        return
    }

    $window.Dispatcher.Invoke($Action)
}

function Initialize-ScreenText {
    <#
        .SYNOPSIS
        Sets every static label and button caption on the v4.2 screens
        from SimRig.Strings.ps1 (requirement G-19). Called once by
        Initialize-ConsoleView. Every value here comes from
        Get-SimRigString - never a literal - which is what the strings
        test in tests/Screens.Tests.ps1 checks.
    #>
    [CmdletBinding()]
    param()

    foreach ($elementName in $script:V42StaticTextMap.Keys) {
        $element = Get-SimRigViewElement -Name $elementName
        if ($null -ne $element) {
            $element.Text = Get-SimRigString -Key $script:V42StaticTextMap[$elementName]
        }
    }

    # Push 2 of the unit tune, step 9 (the Cowork answer to the texts of push 2, answer 6): on the rig,
    # where Apply tuning also writes GPU steering, text 1 has text 7 as a second sentence.
    $changesBody = Get-SimRigViewElement -Name 'TxtFirstRunChangesBody'
    if ($null -ne $changesBody -and (Get-SimRigTuningAllowed)) {
        $changesBody.Text = (Get-SimRigString -Key 'FirstRun_ChangesBody') + ' ' + (Get-SimRigString -Key 'Tuning_ConfirmNoUndoSteering')
    }

    foreach ($controlName in $script:V42AutomationOnlyMap.Keys) {
        $control = Get-SimRigViewElement -Name $controlName
        if ($null -eq $control) {
            continue
        }
        $name = Get-SimRigString -Key $script:V42AutomationOnlyMap[$controlName]
        [System.Windows.Automation.AutomationProperties]::SetName($control, $name)
    }

    foreach ($buttonName in $script:V42ButtonTextMap.Keys) {
        $button = Get-SimRigViewElement -Name $buttonName
        if ($null -eq $button) {
            continue
        }
        $text = Get-SimRigString -Key $script:V42ButtonTextMap[$buttonName]
        $button.Content = $text
        [System.Windows.Automation.AutomationProperties]::SetName($button, $text)
    }
}

function Hide-V42Screen {
    <#
        .SYNOPSIS
        Collapses all six v4.2 screens, so the main screen is what shows.

        .DESCRIPTION
        Show-Screen shows one of the six and hides the other five. There was no way to
        hide all six: the first-run card's Continue button asked Show-Screen for
        'ScreenMain', which is not in its ValidateSet, so the call threw and the card
        stayed on screen.

        This is the way off, and nothing more. Which screens can be REACHED, and from
        where, is a v4.3 question (C1).
    #>
    [CmdletBinding()]
    param()

    foreach ($screenName in $script:ScreenNames) {
        $screen = Get-SimRigViewElement -Name $screenName
        if ($null -eq $screen) { continue }
        $screen.Visibility = [System.Windows.Visibility]::Collapsed
    }
}

function Show-Screen {
    <#
        .SYNOPSIS
        Shows one named v4.2 screen and collapses every other one.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('ScreenFirstRun', 'ScreenMyPc', 'ScreenGaps', 'ScreenScore', 'ScreenShare', 'ScreenAbout')]
        [string]$Name
    )

    foreach ($screenName in $script:ScreenNames) {
        $screen = Get-SimRigViewElement -Name $screenName
        if ($null -eq $screen) {
            continue
        }
        $screen.Visibility = if ($screenName -eq $Name) {
            [System.Windows.Visibility]::Visible
        }
        else {
            [System.Windows.Visibility]::Collapsed
        }
    }
}

function Show-UninstallDialog {
    <#
        .SYNOPSIS
        Shows or hides the uninstall confirmation dialog.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [bool]$Visible
    )

    $dialog = Get-SimRigViewElement -Name 'UninstallDialog'
    if ($null -eq $dialog) {
        return
    }
    $dialog.Visibility = if ($Visible) {
        [System.Windows.Visibility]::Visible
    }
    else {
        [System.Windows.Visibility]::Collapsed
    }
}

function Show-FirstRunSessionPath {
    <#
        .SYNOPSIS
        Sets the default session folder path shown on the First run screen.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Path
    )

    $element = Get-SimRigViewElement -Name 'TxtFirstRunSessionPath'
    if ($null -ne $element) {
        $element.Text = $Path
    }
}

function Show-MyPcCard {
    <#
        .SYNOPSIS
        Replaces one My PC card's rows (Cpu, Gpu, Display, Iracing,
        Peripherals). Rows are the same Name/Detail/Value/Source/Verdict
        shape ConvertTo-PreflightViewRow produces.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Cpu', 'Gpu', 'Display', 'Iracing', 'Peripherals')]
        [string]$Card,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$Row
    )

    $elementNames = @{
        Cpu         = 'MyPcCpuCard'
        Gpu         = 'MyPcGpuCard'
        Display     = 'MyPcDisplayCard'
        Iracing     = 'MyPcIracingCard'
        Peripherals = 'MyPcPeripheralsCard'
    }

    $element = Get-SimRigViewElement -Name $elementNames[$Card]
    if ($null -ne $element) {
        $element.ItemsSource = @($Row)
    }
}

function Show-ToolsList {
    <#
        .SYNOPSIS
        Replaces the Tools card rows. Each row carries Name, Detail
        (what the tool gives), Value (installed/missing/too old plus
        version), InstallLabel and InstallAutomationName for the row's
        Install button, and Source (the winget id, tagged on the button).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$Row
    )

    $element = Get-SimRigViewElement -Name 'ToolsList'
    if ($null -ne $element) {
        $element.ItemsSource = @($Row)
    }
}

function Show-GapsList {
    <#
        .SYNOPSIS
        Replaces the Gaps table rows (Rule, Found, Expected, Evidence,
        Fix), already filtered by severity by the caller.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$Row
    )

    $element = Get-SimRigViewElement -Name 'GapsList'
    if ($null -ne $element) {
        $element.ItemsSource = @($Row)
    }
}

function Show-ScoreCard {
    <#
        .SYNOPSIS
        Replaces the Before or After stutter-score rows.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Before', 'After')]
        [string]$Side,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$Row
    )

    $elementName = if ($Side -eq 'Before') { 'ScoreBeforeCard' } else { 'ScoreAfterCard' }
    $element = Get-SimRigViewElement -Name $elementName
    if ($null -ne $element) {
        $element.ItemsSource = @($Row)
    }
}

function Show-SharePreview {
    <#
        .SYNOPSIS
        Sets the exact anonymized JSON text shown on the Share screen
        before anything is saved or opened.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Json
    )

    $element = Get-SimRigViewElement -Name 'TxtSharePreview'
    if ($null -ne $element) {
        $element.Text = $Json
    }
}

function Show-AboutInfo {
    <#
        .SYNOPSIS
        Sets the About screen's version, commit, file hash and update
        check status line.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Version,

        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Commit,

        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Hash,

        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$UpdateStatus
    )

    $versionElement = Get-SimRigViewElement -Name 'TxtAboutVersion'
    if ($null -ne $versionElement) { $versionElement.Text = $Version }

    $commitElement = Get-SimRigViewElement -Name 'TxtAboutCommit'
    if ($null -ne $commitElement) { $commitElement.Text = $Commit }

    $hashElement = Get-SimRigViewElement -Name 'TxtAboutHash'
    if ($null -ne $hashElement) { $hashElement.Text = $Hash }

    $updateElement = Get-SimRigViewElement -Name 'TxtAboutUpdateStatus'
    if ($null -ne $updateElement) { $updateElement.Text = $UpdateStatus }
}

function Show-AboutInfoUpdateStatus {
    <#
        .SYNOPSIS
        Sets the About screen's update line on its own.

        .DESCRIPTION
        The check writes this line twice - 'Checking for updates...' and then the
        answer - and it must not redraw the version, commit and hash to do it.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Text
    )

    $updateElement = Get-SimRigViewElement -Name 'TxtAboutUpdateStatus'
    if ($null -ne $updateElement) { $updateElement.Text = $Text }
}

function Show-SessionSizeWarn {
    <#
        .SYNOPSIS
        Shows or hides the My PC screen's over-5-GB session folder
        warning, with its text.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [bool]$Visible,

        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Text
    )

    $textElement = Get-SimRigViewElement -Name 'TxtMyPcSessionSizeWarn'
    if ($null -ne $textElement) { $textElement.Text = $Text }

    $banner = Get-SimRigViewElement -Name 'MyPcSessionSizeWarn'
    if ($null -eq $banner) {
        return
    }
    $banner.Visibility = if ($Visible) {
        [System.Windows.Visibility]::Visible
    }
    else {
        [System.Windows.Visibility]::Collapsed
    }
}
