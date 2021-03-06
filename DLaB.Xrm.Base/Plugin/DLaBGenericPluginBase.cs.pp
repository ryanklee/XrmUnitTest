using System;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;

#if DLAB_UNROOT_NAMESPACE || DLAB_XRM
namespace DLaB.Xrm.Plugin
#else
namespace Source.DLaB.Xrm.Plugin
#endif
	
{
    /// <inheritdoc />
    /// <summary>
    /// Plugin Handler Base.  Allows for Registered Events, preventing infinite loops, and auto logging
    /// </summary>
    public abstract class DLaBGenericPluginBase<T> : IRegisteredEventsPlugin where T: IExtendedPluginContext
    {
        #region Constants

        public const string TracePreContext = "PluginBase.TracePreContext";
        public const string TracePrePostContext = "PluginBase.TraceContext";
        public const string TracePostContext = "PluginBase.TracePostContext";

        #endregion Constants

        #region Properties

        private readonly object _handlerLock = new object();
        private volatile bool _isIntialized;
        private IEnumerable<RegisteredEvent> _events;

        /// <inheritdoc />
        public IEnumerable<RegisteredEvent> RegisteredEvents => _events ?? (_events = CreateEvents());

        /// <summary>
        /// Gets or sets the secure configuration.
        /// </summary>
        /// <value>
        /// The secure configuration.
        /// </value>
        public string SecureConfig { get; }
        /// <summary>
        /// Gets or sets the unsecure configuration.
        /// </summary>
        /// <value>
        /// The unsecure configuration.
        /// </value>
        public string UnsecureConfig { get; }

        #endregion Properties

        #region Constructors

        /// <summary>
        /// Initializes a new instance of the GenericPluginHandlerBase class.
        /// </summary>
        /// <param name="unsecureConfig"></param>
        /// <param name="secureConfig"></param>
        protected DLaBGenericPluginBase(string unsecureConfig, string secureConfig)
        {
            SecureConfig = secureConfig;
            UnsecureConfig = unsecureConfig;
        }

        #endregion Constructors

        #region Abstract Methods

        /// <summary>
        /// Creates the local plugin context.
        /// </summary>
        /// <param name="serviceProvider">The service provider.</param>
        /// <returns></returns>
        protected abstract T CreatePluginContext(IServiceProvider serviceProvider);

        /// <summary>
        /// The default method to be executed by the plugin.  The Registered Event could specify a different method.
        /// </summary>
        /// <param name="context">The plugin context.</param>
        protected abstract void ExecuteInternal(T context);

        /// <summary>
        /// Create the Registered Events for the plugin to operate on.
        /// </summary>
        /// <returns></returns>
        protected abstract IEnumerable<RegisteredEvent> CreateEvents();

        #endregion Abstract Methods

        #region Initialize

        private void InitializeMain()
        {
            if (_isIntialized) { return; }

            lock (_handlerLock)
            {
                if (_isIntialized) { return; }

                _isIntialized = true;
                Initialize();
            }
        }

        /// <summary>
        /// Called once directly before the plugin instance is executed for the first time.
        /// </summary>
        protected virtual void Initialize() { }


        #endregion Initialize

        /// <summary>
        /// Executes the plug-in.
        /// </summary>
        /// <param name="serviceProvider">The service provider.</param>
        /// <exception cref="T:System.ArgumentNullException"></exception>
        /// <remarks>
        /// For improved performance, Microsoft Dynamics CRM caches plug-in instances.
        /// The plug-in's Execute method should be written to be stateless as the constructor
        /// is not called for every invocation of the plug-in. Also, multiple system threads
        /// could execute the plug-in at the same time. All per invocation state information
        /// is stored in the context. This means that you should not use class level fields/properties in plug-ins.
        /// </remarks>
        public void Execute(IServiceProvider serviceProvider)
        {
            if (!_isIntialized)
            {
                InitializeMain();
            }
            PreExecute(serviceProvider);

            if (serviceProvider == null)
            {
                throw new ArgumentNullException(nameof(serviceProvider));
            }

            var context = CreatePluginContext(serviceProvider);

            try
            {
                using (context.TraceTime("{0}.Execute()", context.PluginTypeName))
                {
                    if (IsPreContextTraced(context))
                    {
                        context.TraceContext();
                    }

                    if (context.Event == null)
                    {
                        context.Trace("No Registered Event Found for Event: {0}, Entity: {1}, and Stage: {2}!", context.MessageName, context.PrimaryEntityName, context.Stage);
                        return;
                    }

                    if (PreventRecursiveCall(context))
                    {
                        context.Trace("Duplicate Recursive Call Prevented!");
                        return;
                    }

                    if (context.HasPluginHandlerExecutionBeenPrevented())
                    {
                        context.Trace("Context has Specified Call to be Prevented!");
                        return;
                    }

                    if (SkipExecution(context))
                    {
                        context.Trace("Execution Has Been Skipped!");
                        return;
                    }

                    ExecuteRegisteredEvent(context);

                    if (IsPostContextTraced(context))
                    {
                        context.TraceContext();
                    }
                }
            }
            catch (Exception ex)
            {
                if(ExecuteExceptionHandler(ex, context))
                {
                    throw;
                }
            }
            finally
            {
                PostExecute(context);
            }
        }

        /// <summary>
        /// Method that gets called when an exception occurs in the Execute method.  Return true if the exception should be rethrown.
        /// This prevents losing the stack trace by rethrowing the originally caught error.
        /// </summary>
        /// <param name="ex"></param>
        /// <param name="context"></param>
        /// <returns></returns>
        protected virtual bool ExecuteExceptionHandler(Exception ex, T context)
        { 
            context.LogException(ex);
            // Unexpected Exception occurred, log exception then wrap and throw new exception
            if (context.IsolationMode == IsolationMode.Sandbox)
            {
                Sandbox.ExceptionHandler.AssertCanThrow(ex);
            }
            return true;
        }

        /// <summary>
        /// Method that gets called before the Execute
        /// </summary>
        /// <param name="serviceProvider">The service provider.</param>
        protected virtual void PreExecute(IServiceProvider serviceProvider) { }

        /// <summary>
        /// Method that gets called in the finally block of the Execute
        /// </summary>
        /// <param name="context">The context.</param>
        protected virtual void PostExecute(IExtendedPluginContext context) { }

        /// <summary>
        /// Method that gets called directly before Execute(context).  Returning true will skip the Execute(context) from getting called.  
        /// </summary>
        /// <param name="context"></param>
        /// <returns></returns>
        protected virtual bool SkipExecution(T context) { return false; }

        /// <summary>
        /// Traces the Execution of the registered event of the context.
        /// </summary>
        /// <param name="context">The context.</param>
        private void ExecuteRegisteredEvent(T context)
        {
            var execute = context.Event.Execute == null ? ExecuteInternal : new Action<T>(c => context.Event.Execute(c));

            context.Trace("{0}.{1} is Executing for Entity: {2}, Message: {3}",
                context.PluginTypeName,
                context.Event.ExecuteMethodName,
                context.PrimaryEntityName,
                context.MessageName);

            execute(context);
        }

        /// <summary>
        /// Allows Plugin to trigger itself.  Delete Messge Types always return False since you can't delete something twice, all other message types return true if the execution key is found in the shared parameters.
        /// </summary>
        /// <param name="context"></param>
        /// <returns></returns>
        protected virtual bool PreventRecursiveCall(IExtendedPluginContext context)
        {
            if (context.Event.Message == MessageType.Delete)
            {
                return false;
            }

            var sharedVariables = context.SharedVariables;
            var key = $"{context.PluginTypeName}|{context.Event.MessageName}|{context.Event.Stage}|{context.PrimaryEntityId}";
            if (context.GetFirstSharedVariable<int>(key) > 0)
            {
                return true;
            }

            sharedVariables.Add(key, 1);
            return false;
        }

        /// <summary>
        /// Determines if the Context should be traced Pre Execution of the plugin logic
        /// </summary>
        protected virtual bool IsPreContextTraced(T context) { return ContainsAnyIgnoreCase(SecureConfig, TracePreContext, TracePrePostContext); }
        /// <summary>
        /// Determines if the Context should be traced Post Execution of the plugin logic
        /// </summary>
        protected virtual bool IsPostContextTraced(T context) { return ContainsAnyIgnoreCase(SecureConfig, TracePostContext, TracePrePostContext); }

        private bool ContainsAnyIgnoreCase(string source, params string[] values)
        {
            return source != null 
                && values.Any(v => CultureInfo.InvariantCulture.CompareInfo.IndexOf(source, v, CompareOptions.IgnoreCase) >= 0);
        }
    }
}
