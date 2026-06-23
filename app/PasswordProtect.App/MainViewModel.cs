using System.Collections.ObjectModel;
using System.Security;
using System.Windows;
using PasswordProtect.Core;

namespace PasswordProtect.App;

/// <summary>View-model for the simple bulk-protect window.</summary>
public sealed class MainViewModel : ObservableObject
{
    private readonly AppServices _services;

    public MainViewModel(AppServices services)
    {
        _services = services;
        Files.CollectionChanged += (_, _) =>
        {
            OnPropertyChanged(nameof(CanRun));
            OnPropertyChanged(nameof(HasNoFiles));
        };
    }

    public ObservableCollection<FileItem> Files { get; } = new();

    /// <summary>Visible when the queue is empty, to show the "drag files here" hint.</summary>
    public Visibility HasNoFiles => Files.Count == 0 ? Visibility.Visible : Visibility.Collapsed;

    private bool _busy;
    public bool Busy
    {
        get => _busy;
        set { if (Set(ref _busy, value)) OnPropertyChanged(nameof(CanRun)); }
    }

    public bool CanRun => !Busy && Files.Count > 0;

    private string _status = "Drop files here, or click Add Files.";
    public string Status { get => _status; set => Set(ref _status, value); }

    private bool _overwrite;
    public bool Overwrite { get => _overwrite; set => Set(ref _overwrite, value); }

    /// <summary>The output naming template; supports tokens incl. {DetectedName}/{DetectedDate}.</summary>
    public string Template
    {
        get => _services.Settings.NamingTemplate;
        set
        {
            if (value != _services.Settings.NamingTemplate)
            {
                _services.Settings.NamingTemplate = value;
                OnPropertyChanged();
            }
        }
    }

    /// <summary>Fill each row with the planned output name (running detection if the template needs it).</summary>
    public async Task PreviewAsync()
    {
        if (Files.Count == 0) return;
        Busy = true;
        Status = "Previewing names…";
        _services.Settings.AllowOverwrite = Overwrite;
        try
        {
            foreach (FileItem item in Files)
            {
                DetectedFields detected = await _services.DetectAsync(item.InputPath);
                ProtectionJob job = _services.BuildJob(item.InputPath, detected);
                item.Message = "→ " + Path.GetFileName(job.OutputPath);
            }
            Status = "Preview ready — click Protect to apply.";
        }
        finally
        {
            Busy = false;
        }
    }

    public void AddFiles(IEnumerable<string> paths)
    {
        foreach (string p in paths)
        {
            if (File.Exists(p) &&
                !Files.Any(f => string.Equals(f.InputPath, p, StringComparison.OrdinalIgnoreCase)))
            {
                Files.Add(new FileItem(p));
            }
        }
        Status = Files.Count == 0 ? "Drop files here, or click Add Files." : $"{Files.Count} file(s) ready.";
    }

    public void Clear()
    {
        Files.Clear();
        Status = "Cleared.";
    }

    /// <summary>Protect every queued file. Takes ownership of <paramref name="password"/> and disposes it.</summary>
    public async Task RunAsync(SecureString password)
    {
        if (Files.Count == 0) { password.Dispose(); return; }

        Busy = true;
        Status = "Protecting…";
        _services.Settings.AllowOverwrite = Overwrite;

        var byInput = new Dictionary<string, FileItem>(StringComparer.OrdinalIgnoreCase);
        var jobs = new List<ProtectionJob>();
        foreach (FileItem item in Files)
        {
            item.Status = "Pending";
            item.Message = "";
            DetectedFields detected = await _services.DetectAsync(item.InputPath);
            byInput[item.InputPath] = item;
            jobs.Add(_services.BuildJob(item.InputPath, detected));
        }

        var progress = new Progress<BatchProgress>(p =>
        {
            if (byInput.TryGetValue(p.Job.InputPath, out FileItem? fi))
            {
                fi.Status = p.Job.Status.ToString();
                fi.Message = p.Job.Message;
                fi.OutputPath = p.Job.OutputPath;
            }
            Status = $"{p.Completed}/{p.Total} processed…";
        });

        try
        {
            await _services.Batch.RunAsync(
                jobs, password, _services.Settings.ToProtectOptions(), _services.Settings.MaxParallel, progress);
            int ok = jobs.Count(j => j.Status == JobStatus.Succeeded);
            Status = $"Done — {ok} of {jobs.Count} protected.";
        }
        catch (Exception ex)
        {
            Status = "Error: " + ex.Message;
        }
        finally
        {
            password.Dispose();
            Busy = false;
        }
    }
}
