CLASS zexport_bundle_in_tdc DEFINITION
  PUBLIC
  FINAL
  CREATE PUBLIC
  INHERITING FROM zexport_bundle.

  PUBLIC SECTION.

    METHODS constructor
      IMPORTING
        !tdc     TYPE REF TO cl_apl_ecatt_tdc_api
        !variant TYPE etvar_id
      RAISING
        cx_ecatt_tdc_access .
    "! Add the content of the table to the bundle (uses the builder-pattern).
    "! @parameter _table |
    "! <ul>
    "! <li> Component "source_table":
    "!   Database table (transparent table), where the content lies.
    "! </li>
    "! <li> Component "fake_table":
    "! The fake table, which is used in the unit-test.
    "! The import-class <em>zimport_bundle_from_cluster</em>
    "! overwrites the content of the fake-table.
    "! This parameter can be used, if working with class <em>cl_osq_replace</em>
    "! to replace table contents.
    "! If this parameter is omitted, parameter <em>table</em> is used.
    "! </li>
    "! <li> Component "where_restriction":
    "! An valid sql-where-clause for an restriction of the exported rows.
    "! </li>
    "! </ul>
    "! @raising zcx_export_error | If a table name is
    "! used more than one time or,
    "! if the "where_restriction" is invalid.
    METHODS add_table_to_bundle
      IMPORTING
        VALUE(_table)   TYPE zexport_table_list
      RETURNING
        VALUE(instance) TYPE REF TO zexport_bundle_in_tdc
      RAISING
        zcx_export_error .
    METHODS export
      IMPORTING
        !transport_request TYPE e070-trkorr
      RAISING
        zcx_export_error .
    METHODS add_prior_content
      IMPORTING
        table_conjunction TYPE zexport_table_list
      RAISING
        zcx_export_error .
  PROTECTED SECTION.
    METHODS get_exported_content REDEFINITION.
  PRIVATE SECTION.

    DATA tdc TYPE REF TO cl_apl_ecatt_tdc_api .
    DATA variant TYPE etvar_id .

    METHODS create_parameter
      IMPORTING
        !table      TYPE tabname
      RETURNING
        VALUE(name) TYPE etp_name
      RAISING
        zcx_export_error
        cx_ecatt_tdc_access .
    METHODS set_parameter_value
      IMPORTING
        !content TYPE STANDARD TABLE
        !name    TYPE etp_name
      RAISING
        cx_ecatt_tdc_access .
    "! Invalid characters for ecatt parameters are replaced by '_'.
    METHODS get_parameter_name
      IMPORTING
        !table_name   TYPE tabname
      RETURNING
        VALUE(result) TYPE etp_name .
    METHODS get_parameter_definition
      IMPORTING
        !table_name   TYPE tabname
      RETURNING
        VALUE(result) TYPE string
      RAISING
        zcx_export_error.
    METHODS search_for_table_types
      IMPORTING
        !table_name   TYPE tabname
      RETURNING
        VALUE(result) TYPE ttypename
      RAISING
        zcx_export_error.
    METHODS is_cluster_table
      IMPORTING
        !table_name   TYPE tabname
      RETURNING
        VALUE(result) TYPE sap_bool .
ENDCLASS.



CLASS ZEXPORT_BUNDLE_IN_TDC IMPLEMENTATION.


  METHOD add_prior_content.

    IF line_exists( table_list[ fake_table = table_conjunction-fake_table ] ).
      RAISE EXCEPTION TYPE zcx_export_table_duplicate
        EXPORTING
          table = table_conjunction-fake_table.
    ENDIF.

    INSERT table_conjunction INTO TABLE table_list.

  ENDMETHOD.


  METHOD add_table_to_bundle.
    DATA: content    TYPE REF TO data,
          param_name TYPE etp_name.
    FIELD-SYMBOLS: <con> TYPE STANDARD TABLE.

    " Parameters in test data containers can only refer to the
    " CDS-Database-view. So write CDS-Database-view-name to fake table name.
    IF zexport_utils=>is_cds_view_entity( _table-source_table ) = abap_true.
      _table-fake_table = zexport_utils=>get_cds_view_name( _table-source_table ).
    ELSEIF _table-fake_table IS INITIAL.
      _table-fake_table = _table-source_table.
    ENDIF.
    IF line_exists( table_list[ fake_table = _table-fake_table ] ).
      RAISE EXCEPTION TYPE zcx_export_table_duplicate
        EXPORTING
          table = _table-fake_table.
    ENDIF.

    TRY.
        _table-tdc_parameter_name = create_parameter( _table-fake_table ).

        CREATE DATA content TYPE STANDARD TABLE OF (_table-fake_table).
        ASSIGN content->* TO <con>.

        select( EXPORTING table_conjunction = _table
          IMPORTING content = <con> ).
        _table-is_initial = xsdbool( <con> IS INITIAL ).

        set_parameter_value( content = <con> name = _table-tdc_parameter_name ).

        INSERT _table INTO TABLE table_list.

      CATCH cx_ecatt_tdc_access INTO DATA(ecatt_failure).
        zcx_export_error=>wrap_ecatt_failure( ecatt_failure ).
    ENDTRY.

  ENDMETHOD.


  METHOD constructor.

    super->constructor( ).
    me->tdc = tdc.
    me->variant = variant.

    " create variant, if not exists
    TRY.
        tdc->create_variant( i_variant_name = variant ).
      CATCH cx_ecatt_tdc_access INTO DATA(failure).
        IF failure->textid <> cx_ecatt_tdc_access=>variant_exists.
          RAISE EXCEPTION failure.
        ENDIF.
    ENDTRY.

  ENDMETHOD.


  METHOD create_parameter.
    DATA: type_definition TYPE string.

    type_definition = get_parameter_definition( table ).
    name = get_parameter_name( table ).

    TRY.
        tdc->create_parameter( i_param_name = name
          i_param_def = type_definition ).
      CATCH cx_ecatt_tdc_access INTO DATA(failure).
        IF failure->textid = cx_ecatt_tdc_access=>parameter_exists.
          IF tdc->get_param_definition( name ) <> type_definition.
            tdc->change_parameter( i_param_name = name
              i_param_def = type_definition ).
          ENDIF.
        ELSE.
          RAISE EXCEPTION failure.
        ENDIF.
    ENDTRY.

  ENDMETHOD.


  METHOD export.

    TRY.
        DATA(param_for_list) = create_parameter( table = 'ZEXPORT_TABLE_LIST' ).
        set_parameter_value( content = table_list name = param_for_list ).

        tdc->commit_changes( i_commit_mode = abap_false
          i_tr_order = transport_request i_release_lock = abap_true ).

      CATCH cx_ecatt_tdc_access INTO DATA(ecatt_failure).
        zcx_export_error=>wrap_ecatt_failure( ecatt_failure ).
    ENDTRY.

  ENDMETHOD.


  METHOD get_exported_content.

    ASSIGN table_for_all_entries->* TO FIELD-SYMBOL(<content>).
    select( EXPORTING table_conjunction = table_conjunction
      IMPORTING content = <content> ).

  ENDMETHOD.


  METHOD get_parameter_definition.

    " search for table types first as type "standard table of" for cluster tables
    " is changed to character like type in TDC, which causes a dump
    result = search_for_table_types( table_name ).
    IF result IS NOT INITIAL.
      RETURN.
    ENDIF.

    CONCATENATE 'STANDARD TABLE OF' table_name INTO result
      SEPARATED BY space.

  ENDMETHOD.


  METHOD get_parameter_name.

    result = table_name.
    REPLACE ALL OCCURRENCES OF REGEX '[^A-Za-z0-9_\s]'
      IN result WITH '_'.

  ENDMETHOD.


  METHOD is_cluster_table.

    SELECT COUNT(*) FROM dd02l
      WHERE tabname = @table_name AND as4local = 'A' AND tabclass = 'CLUSTER'.
    result = xsdbool( sy-subrc = 0 ).

  ENDMETHOD.


  METHOD search_for_table_types.
    DATA:
      objects_to_search    TYPE STANDARD TABLE OF rsfind,
      scope_object_classes TYPE STANDARD TABLE OF seu_obj,
      found_table_types    TYPE STANDARD TABLE OF rsfindlst,
      table_type_range     TYPE RANGE OF ttypename.

    objects_to_search = VALUE #( ( object = table_name ) ).
    scope_object_classes = VALUE #( ( 'DA' ) ).
    CALL FUNCTION 'RS_EU_CROSSREF'
      EXPORTING
        i_find_obj_cls               = 'DS'
        i_answer                     = 'N'
        no_dialog                    = abap_true
        expand_source_in_online_mode = abap_true
        rekursiv                     = abap_true
      TABLES
        i_findstrings                = objects_to_search
        i_scope_object_cls           = scope_object_classes
        o_founds                     = found_table_types
      EXCEPTIONS
        OTHERS                       = 4.
    IF ( sy-subrc <> 0 OR found_table_types IS INITIAL )
        AND is_cluster_table( table_name ) = abap_true.
      RAISE EXCEPTION TYPE zcx_export_cluster_table
        EXPORTING
          table_name = table_name.
    ELSEIF found_table_types IS INITIAL.
      RETURN.
    ENDIF.

    table_type_range = VALUE #(
      FOR <table_type> IN found_table_types
      ( sign = 'I' option = 'EQ' low = <table_type>-object ) ).
    SELECT typename FROM dd40l
      WHERE typename IN @table_type_range AND as4local = 'A' AND accessmode = 'T'
      INTO @result.
    ENDSELECT.
    IF sy-subrc <> 0 AND is_cluster_table( table_name ) = abap_true.
      RAISE EXCEPTION TYPE zcx_export_cluster_table
        EXPORTING
          table_name = table_name.
    ENDIF.

  ENDMETHOD.


  METHOD set_parameter_value.

    tdc->set_value( i_param_name = name i_param_value = content
      i_variant_name = variant ).

  ENDMETHOD.
ENDCLASS.
