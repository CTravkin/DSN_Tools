using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;

namespace DSNTools.WindowsAudioProfile
{
    internal enum EDataFlow
    {
        Render = 0,
        Capture = 1,
        All = 2
    }

    internal enum ERole
    {
        Console = 0,
        Multimedia = 1,
        Communications = 2
    }

    [Flags]
    internal enum ClsCtx : uint
    {
        InprocServer = 0x1,
        LocalServer = 0x4,
        All = InprocServer | LocalServer
    }

    [ComImport]
    [Guid("BCDE0395-E52F-467C-8E3D-C4579291692E")]
    internal class MMDeviceEnumeratorComObject
    {
    }

    [ComImport]
    [Guid("A95664D2-9614-4F35-A746-DE8DB63617E6")]
    [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    internal interface IMMDeviceEnumerator
    {
        [PreserveSig]
        int EnumAudioEndpoints(EDataFlow dataFlow, uint stateMask, out IntPtr devices);

        [PreserveSig]
        int GetDefaultAudioEndpoint(EDataFlow dataFlow, ERole role, out IMMDevice endpoint);

        [PreserveSig]
        int GetDevice([MarshalAs(UnmanagedType.LPWStr)] string id, out IMMDevice endpoint);

        [PreserveSig]
        int RegisterEndpointNotificationCallback(IntPtr client);

        [PreserveSig]
        int UnregisterEndpointNotificationCallback(IntPtr client);
    }

    [ComImport]
    [Guid("D666063F-1587-4E43-81F1-B948E807363F")]
    [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    internal interface IMMDevice
    {
        [PreserveSig]
        int Activate(ref Guid iid, ClsCtx clsCtx, IntPtr activationParams, [MarshalAs(UnmanagedType.IUnknown)] out object instance);

        [PreserveSig]
        int OpenPropertyStore(uint access, out IntPtr properties);

        [PreserveSig]
        int GetId([MarshalAs(UnmanagedType.LPWStr)] out string id);

        [PreserveSig]
        int GetState(out uint state);
    }

    [ComImport]
    [Guid("5CDF2C82-841E-4546-9722-0CF74078229A")]
    [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    internal interface IAudioEndpointVolume
    {
        [PreserveSig] int RegisterControlChangeNotify(IntPtr notify);
        [PreserveSig] int UnregisterControlChangeNotify(IntPtr notify);
        [PreserveSig] int GetChannelCount(out uint channelCount);
        [PreserveSig] int SetMasterVolumeLevel(float levelDb, ref Guid eventContext);
        [PreserveSig] int SetMasterVolumeLevelScalar(float level, ref Guid eventContext);
        [PreserveSig] int GetMasterVolumeLevel(out float levelDb);
        [PreserveSig] int GetMasterVolumeLevelScalar(out float level);
        [PreserveSig] int SetChannelVolumeLevel(uint channel, float levelDb, ref Guid eventContext);
        [PreserveSig] int SetChannelVolumeLevelScalar(uint channel, float level, ref Guid eventContext);
        [PreserveSig] int GetChannelVolumeLevel(uint channel, out float levelDb);
        [PreserveSig] int GetChannelVolumeLevelScalar(uint channel, out float level);
        [PreserveSig] int SetMute([MarshalAs(UnmanagedType.Bool)] bool mute, ref Guid eventContext);
        [PreserveSig] int GetMute([MarshalAs(UnmanagedType.Bool)] out bool mute);
        [PreserveSig] int GetVolumeStepInfo(out uint step, out uint stepCount);
        [PreserveSig] int VolumeStepUp(ref Guid eventContext);
        [PreserveSig] int VolumeStepDown(ref Guid eventContext);
        [PreserveSig] int QueryHardwareSupport(out uint hardwareSupportMask);
        [PreserveSig] int GetVolumeRange(out float minimumDb, out float maximumDb, out float incrementDb);
    }

    [ComImport]
    [Guid("870AF99C-171D-4F9E-AF0D-E63DF40C2BC9")]
    internal class PolicyConfigClientComObject
    {
    }

    [ComImport]
    [Guid("F8679F50-850A-41CF-9C72-430F290290C8")]
    [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    internal interface IPolicyConfig
    {
        [PreserveSig] int GetMixFormat([MarshalAs(UnmanagedType.LPWStr)] string deviceId, out IntPtr format);
        [PreserveSig] int GetDeviceFormat([MarshalAs(UnmanagedType.LPWStr)] string deviceId, [MarshalAs(UnmanagedType.Bool)] bool defaultFormat, out IntPtr format);
        [PreserveSig] int ResetDeviceFormat([MarshalAs(UnmanagedType.LPWStr)] string deviceId);
        [PreserveSig] int SetDeviceFormat([MarshalAs(UnmanagedType.LPWStr)] string deviceId, IntPtr endpointFormat, IntPtr mixFormat);
        [PreserveSig] int GetProcessingPeriod([MarshalAs(UnmanagedType.LPWStr)] string deviceId, [MarshalAs(UnmanagedType.Bool)] bool defaultPeriod, out long period, out long minimumPeriod);
        [PreserveSig] int SetProcessingPeriod([MarshalAs(UnmanagedType.LPWStr)] string deviceId, ref long period);
        [PreserveSig] int GetShareMode([MarshalAs(UnmanagedType.LPWStr)] string deviceId, IntPtr mode);
        [PreserveSig] int SetShareMode([MarshalAs(UnmanagedType.LPWStr)] string deviceId, IntPtr mode);
        [PreserveSig] int GetPropertyValue([MarshalAs(UnmanagedType.LPWStr)] string deviceId, [MarshalAs(UnmanagedType.Bool)] bool store, IntPtr key, IntPtr value);
        [PreserveSig] int SetPropertyValue([MarshalAs(UnmanagedType.LPWStr)] string deviceId, [MarshalAs(UnmanagedType.Bool)] bool store, IntPtr key, IntPtr value);
        [PreserveSig] int SetDefaultEndpoint([MarshalAs(UnmanagedType.LPWStr)] string deviceId, ERole role);
        [PreserveSig] int SetEndpointVisibility([MarshalAs(UnmanagedType.LPWStr)] string deviceId, [MarshalAs(UnmanagedType.Bool)] bool visible);
    }

    public sealed class EndpointVolumeState
    {
        public float Scalar { get; set; }
        public float Decibels { get; set; }
        public float MinimumDecibels { get; set; }
        public float MaximumDecibels { get; set; }
        public float IncrementDecibels { get; set; }
        public bool Muted { get; set; }
    }

    [StructLayout(LayoutKind.Sequential)]
    internal struct PropertyKey
    {
        public Guid FormatId;
        public uint PropertyId;
    }

    public static class CoreAudio
    {
        private static void Check(int result, string operation)
        {
            if (result < 0) Marshal.ThrowExceptionForHR(result, new IntPtr(-1));
        }

        private static IMMDeviceEnumerator CreateEnumerator()
        {
            return (IMMDeviceEnumerator)new MMDeviceEnumeratorComObject();
        }

        private static IAudioEndpointVolume OpenVolume(IMMDevice device)
        {
            Guid iid = typeof(IAudioEndpointVolume).GUID;
            object instance;
            Check(device.Activate(ref iid, ClsCtx.All, IntPtr.Zero, out instance), "IMMDevice.Activate");
            return (IAudioEndpointVolume)instance;
        }

        public static EndpointVolumeState GetVolume(string endpointId)
        {
            IMMDeviceEnumerator enumerator = null;
            IMMDevice device = null;
            IAudioEndpointVolume volume = null;
            try
            {
                enumerator = CreateEnumerator();
                Check(enumerator.GetDevice(endpointId, out device), "IMMDeviceEnumerator.GetDevice");
                volume = OpenVolume(device);
                float scalar;
                float decibels;
                float minimum;
                float maximum;
                float increment;
                bool muted;
                Check(volume.GetMasterVolumeLevelScalar(out scalar), "IAudioEndpointVolume.GetMasterVolumeLevelScalar");
                Check(volume.GetMasterVolumeLevel(out decibels), "IAudioEndpointVolume.GetMasterVolumeLevel");
                Check(volume.GetVolumeRange(out minimum, out maximum, out increment), "IAudioEndpointVolume.GetVolumeRange");
                Check(volume.GetMute(out muted), "IAudioEndpointVolume.GetMute");
                return new EndpointVolumeState
                {
                    Scalar = scalar,
                    Decibels = decibels,
                    MinimumDecibels = minimum,
                    MaximumDecibels = maximum,
                    IncrementDecibels = increment,
                    Muted = muted
                };
            }
            finally
            {
                if (volume != null) Marshal.FinalReleaseComObject(volume);
                if (device != null) Marshal.FinalReleaseComObject(device);
                if (enumerator != null) Marshal.FinalReleaseComObject(enumerator);
            }
        }

        public static void SetVolumeScalar(string endpointId, float scalar)
        {
            IMMDeviceEnumerator enumerator = null;
            IMMDevice device = null;
            IAudioEndpointVolume volume = null;
            try
            {
                enumerator = CreateEnumerator();
                Check(enumerator.GetDevice(endpointId, out device), "IMMDeviceEnumerator.GetDevice");
                volume = OpenVolume(device);
                Guid context = Guid.Empty;
                Check(volume.SetMasterVolumeLevelScalar(scalar, ref context), "IAudioEndpointVolume.SetMasterVolumeLevelScalar");
            }
            finally
            {
                if (volume != null) Marshal.FinalReleaseComObject(volume);
                if (device != null) Marshal.FinalReleaseComObject(device);
                if (enumerator != null) Marshal.FinalReleaseComObject(enumerator);
            }
        }

        public static void SetVolumeDecibels(string endpointId, float decibels)
        {
            IMMDeviceEnumerator enumerator = null;
            IMMDevice device = null;
            IAudioEndpointVolume volume = null;
            try
            {
                enumerator = CreateEnumerator();
                Check(enumerator.GetDevice(endpointId, out device), "IMMDeviceEnumerator.GetDevice");
                volume = OpenVolume(device);
                Guid context = Guid.Empty;
                Check(volume.SetMasterVolumeLevel(decibels, ref context), "IAudioEndpointVolume.SetMasterVolumeLevel");
            }
            finally
            {
                if (volume != null) Marshal.FinalReleaseComObject(volume);
                if (device != null) Marshal.FinalReleaseComObject(device);
                if (enumerator != null) Marshal.FinalReleaseComObject(enumerator);
            }
        }

        public static void SetMute(string endpointId, bool muted)
        {
            IMMDeviceEnumerator enumerator = null;
            IMMDevice device = null;
            IAudioEndpointVolume volume = null;
            try
            {
                enumerator = CreateEnumerator();
                Check(enumerator.GetDevice(endpointId, out device), "IMMDeviceEnumerator.GetDevice");
                volume = OpenVolume(device);
                Guid context = Guid.Empty;
                Check(volume.SetMute(muted, ref context), "IAudioEndpointVolume.SetMute");
            }
            finally
            {
                if (volume != null) Marshal.FinalReleaseComObject(volume);
                if (device != null) Marshal.FinalReleaseComObject(device);
                if (enumerator != null) Marshal.FinalReleaseComObject(enumerator);
            }
        }

        public static void SetDefaultEndpoint(string endpointId, int role)
        {
            IPolicyConfig policy = null;
            try
            {
                policy = (IPolicyConfig)new PolicyConfigClientComObject();
                Check(policy.SetDefaultEndpoint(endpointId, (ERole)role), "IPolicyConfig.SetDefaultEndpoint");
            }
            finally
            {
                if (policy != null) Marshal.FinalReleaseComObject(policy);
            }
        }

        public static void SetEndpointVisibility(string endpointId, bool visible)
        {
            IPolicyConfig policy = null;
            try
            {
                policy = (IPolicyConfig)new PolicyConfigClientComObject();
                Check(policy.SetEndpointVisibility(endpointId, visible), "IPolicyConfig.SetEndpointVisibility");
            }
            finally
            {
                if (policy != null) Marshal.FinalReleaseComObject(policy);
            }
        }

        private static void SetProperty(string endpointId, Guid formatId, uint propertyId, ushort variantType, IntPtr data, int dataLength)
        {
            IPolicyConfig policy = null;
            IntPtr keyPointer = IntPtr.Zero;
            IntPtr valuePointer = IntPtr.Zero;
            try
            {
                policy = (IPolicyConfig)new PolicyConfigClientComObject();
                PropertyKey key = new PropertyKey { FormatId = formatId, PropertyId = propertyId };
                keyPointer = Marshal.AllocCoTaskMem(Marshal.SizeOf(typeof(PropertyKey)));
                Marshal.StructureToPtr(key, keyPointer, false);
                valuePointer = Marshal.AllocCoTaskMem(24);
                for (int offset = 0; offset < 24; offset += 4) Marshal.WriteInt32(valuePointer, offset, 0);
                Marshal.WriteInt16(valuePointer, 0, unchecked((short)variantType));
                if (variantType == 31)
                {
                    Marshal.WriteIntPtr(valuePointer, 8, data);
                }
                else if (variantType == 65)
                {
                    Marshal.WriteInt32(valuePointer, 8, dataLength);
                    Marshal.WriteIntPtr(valuePointer, 16, data);
                }
                else
                {
                    throw new ArgumentOutOfRangeException("variantType");
                }
                Check(policy.SetPropertyValue(endpointId, false, keyPointer, valuePointer), "IPolicyConfig.SetPropertyValue");
            }
            finally
            {
                if (valuePointer != IntPtr.Zero) Marshal.FreeCoTaskMem(valuePointer);
                if (keyPointer != IntPtr.Zero) Marshal.FreeCoTaskMem(keyPointer);
                if (policy != null) Marshal.FinalReleaseComObject(policy);
            }
        }

        public static void SetStringProperty(string endpointId, string formatId, uint propertyId, string value)
        {
            IntPtr text = IntPtr.Zero;
            try
            {
                text = Marshal.StringToCoTaskMemUni(value);
                SetProperty(endpointId, new Guid(formatId), propertyId, 31, text, 0);
            }
            finally
            {
                if (text != IntPtr.Zero) Marshal.FreeCoTaskMem(text);
            }
        }

        public static void SetBlobProperty(string endpointId, string formatId, uint propertyId, byte[] value)
        {
            IntPtr blob = IntPtr.Zero;
            try
            {
                blob = Marshal.AllocCoTaskMem(value.Length);
                Marshal.Copy(value, 0, blob, value.Length);
                SetProperty(endpointId, new Guid(formatId), propertyId, 65, blob, value.Length);
            }
            finally
            {
                if (blob != IntPtr.Zero) Marshal.FreeCoTaskMem(blob);
            }
        }

        public static string GetDefaultEndpoint(int flow, int role)
        {
            IMMDeviceEnumerator enumerator = null;
            IMMDevice device = null;
            try
            {
                enumerator = CreateEnumerator();
                int result = enumerator.GetDefaultAudioEndpoint((EDataFlow)flow, (ERole)role, out device);
                const int E_NOTFOUND = unchecked((int)0x80070490);
                if (result == E_NOTFOUND) return null;
                Check(result, "IMMDeviceEnumerator.GetDefaultAudioEndpoint");
                string id;
                Check(device.GetId(out id), "IMMDevice.GetId");
                return id;
            }
            finally
            {
                if (device != null) Marshal.FinalReleaseComObject(device);
                if (enumerator != null) Marshal.FinalReleaseComObject(enumerator);
            }
        }
    }

    public static class TokenRunner
    {
        private const uint ProcessQueryLimitedInformation = 0x1000;
        private const uint TokenAssignPrimary = 0x0001;
        private const uint TokenDuplicate = 0x0002;
        private const uint TokenQuery = 0x0008;
        private const uint MaximumAllowed = 0x02000000;
        private const int SecurityImpersonation = 2;
        private const int TokenPrimary = 1;
        private const uint CreateNoWindow = 0x08000000;
        private const uint WaitFailed = 0xFFFFFFFF;
        private const uint WaitTimeout = 0x00000102;

        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        private struct StartupInfo
        {
            public int Size;
            public string Reserved;
            public string Desktop;
            public string Title;
            public uint X;
            public uint Y;
            public uint XSize;
            public uint YSize;
            public uint XCountChars;
            public uint YCountChars;
            public uint FillAttribute;
            public uint Flags;
            public short ShowWindow;
            public short Reserved2Size;
            public IntPtr Reserved2;
            public IntPtr StandardInput;
            public IntPtr StandardOutput;
            public IntPtr StandardError;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct ProcessInformation
        {
            public IntPtr Process;
            public IntPtr Thread;
            public uint ProcessId;
            public uint ThreadId;
        }

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern IntPtr OpenProcess(uint access, bool inheritHandle, uint processId);

        [DllImport("advapi32.dll", SetLastError = true)]
        private static extern bool OpenProcessToken(IntPtr process, uint access, out IntPtr token);

        [DllImport("advapi32.dll", SetLastError = true)]
        private static extern bool DuplicateTokenEx(IntPtr existingToken, uint access, IntPtr attributes, int impersonationLevel, int tokenType, out IntPtr newToken);

        [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern bool CreateProcessWithTokenW(IntPtr token, uint logonFlags, string applicationName, StringBuilder commandLine, uint creationFlags, IntPtr environment, string currentDirectory, ref StartupInfo startupInfo, out ProcessInformation processInformation);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern uint WaitForSingleObject(IntPtr handle, uint milliseconds);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool TerminateProcess(IntPtr process, uint exitCode);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool GetExitCodeProcess(IntPtr process, out uint exitCode);

        [DllImport("kernel32.dll")]
        private static extern bool CloseHandle(IntPtr handle);

        private static Win32Exception LastError(string operation)
        {
            return new Win32Exception(Marshal.GetLastWin32Error(), operation);
        }

        public static uint RunFromProcessToken(uint sourceProcessId, string applicationPath, string arguments, string workingDirectory, uint timeoutMilliseconds)
        {
            IntPtr process = IntPtr.Zero;
            IntPtr sourceToken = IntPtr.Zero;
            IntPtr primaryToken = IntPtr.Zero;
            ProcessInformation processInformation = new ProcessInformation();
            try
            {
                process = OpenProcess(ProcessQueryLimitedInformation, false, sourceProcessId);
                if (process == IntPtr.Zero) throw LastError("OpenProcess failed");
                if (!OpenProcessToken(process, TokenAssignPrimary | TokenDuplicate | TokenQuery, out sourceToken)) throw LastError("OpenProcessToken failed");
                if (!DuplicateTokenEx(sourceToken, MaximumAllowed, IntPtr.Zero, SecurityImpersonation, TokenPrimary, out primaryToken)) throw LastError("DuplicateTokenEx failed");
                StartupInfo startupInfo = new StartupInfo();
                startupInfo.Size = Marshal.SizeOf(typeof(StartupInfo));
                StringBuilder commandLine = new StringBuilder(arguments);
                if (!CreateProcessWithTokenW(primaryToken, 0, applicationPath, commandLine, CreateNoWindow, IntPtr.Zero, workingDirectory, ref startupInfo, out processInformation)) throw LastError("CreateProcessWithTokenW failed");
                uint waitResult = WaitForSingleObject(processInformation.Process, timeoutMilliseconds);
                if (waitResult == WaitTimeout)
                {
                    if (!TerminateProcess(processInformation.Process, 1460)) throw LastError("TerminateProcess failed after timeout");
                    WaitForSingleObject(processInformation.Process, 5000);
                    throw new TimeoutException("TrustedInstaller child process exceeded its execution timeout.");
                }
                if (waitResult == WaitFailed) throw LastError("WaitForSingleObject failed");
                uint exitCode;
                if (!GetExitCodeProcess(processInformation.Process, out exitCode)) throw LastError("GetExitCodeProcess failed");
                return exitCode;
            }
            finally
            {
                if (processInformation.Thread != IntPtr.Zero) CloseHandle(processInformation.Thread);
                if (processInformation.Process != IntPtr.Zero) CloseHandle(processInformation.Process);
                if (primaryToken != IntPtr.Zero) CloseHandle(primaryToken);
                if (sourceToken != IntPtr.Zero) CloseHandle(sourceToken);
                if (process != IntPtr.Zero) CloseHandle(process);
            }
        }
    }
}
