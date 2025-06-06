!--------------------------------------------------------------------------------------------------!
!   CP2K: A general program to perform molecular dynamics simulations                              !
!   Copyright 2000-2025 CP2K developers group <https://cp2k.org>                                   !
!                                                                                                  !
!   SPDX-License-Identifier: GPL-2.0-or-later                                                      !
!--------------------------------------------------------------------------------------------------!

! **************************************************************************************************
!> \brief Environment for NEGF based quantum transport calculations
!> \author Sergey Chulkov
! **************************************************************************************************

MODULE negf_subgroup_types
   USE cp_blacs_env,                    ONLY: cp_blacs_env_create,&
                                              cp_blacs_env_release,&
                                              cp_blacs_env_type
   USE message_passing,                 ONLY: mp_comm_type,&
                                              mp_para_env_release,&
                                              mp_para_env_type
   USE negf_control_types,              ONLY: negf_control_type
#include "./base/base_uses.f90"

   IMPLICIT NONE
   PRIVATE

   CHARACTER(len=*), PARAMETER, PRIVATE :: moduleN = 'negf_subgroup_types'
   LOGICAL, PARAMETER, PRIVATE          :: debug_this_module = .TRUE.

   PUBLIC :: negf_subgroup_env_type, negf_sub_env_create, negf_sub_env_release

! **************************************************************************************************
!> \brief Parallel (sub)group environment.
!> \par History
!>   * 06.2017 created [Sergey Chulkov]
! **************************************************************************************************
   TYPE negf_subgroup_env_type
      !> number of parallel groups.
      !> If it is >1 then the global MPI communicator has actually been split into subgroups.
      !> All other components of the structure are always initialised regardless of the split status
      !> (they simply point to the corresponding global variables if no splitting has been made).
      INTEGER                                            :: ngroups = -1
      !> global MPI rank of the given processor. Local MPI rank can be obtained as para_env%mepos.
      !> Useful to find out the current group index by accessing the 'group_distribution' array.
      INTEGER                                            :: mepos_global = -1
      !> global MPI communicator
      TYPE(mp_comm_type)                                 :: mpi_comm_global = mp_comm_type()
      !> group_distribution(0:num_pe) : a process with rank 'i' belongs to the parallel group
      !> with index 'group_distribution(i)'
      INTEGER, DIMENSION(:), ALLOCATABLE                 :: group_distribution
      !> group-specific BLACS parallel environment
      TYPE(cp_blacs_env_type), POINTER                   :: blacs_env => NULL()
      !> group-specific MPI parallel environment
      TYPE(mp_para_env_type), POINTER                    :: para_env => NULL()
   END TYPE negf_subgroup_env_type

CONTAINS

! **************************************************************************************************
!> \brief Split MPI communicator to create a set of parallel (sub)groups.
!> \param sub_env           parallel (sub)group environment (initialised on exit)
!> \param negf_control      NEGF input control
!> \param blacs_env_global  BLACS environment for all the processors
!> \param blacs_grid_layout BLACS grid layout
!> \param blacs_repeatable  BLACS repeatable layout
!> \par History
!>    * 06.2017 created [Sergey Chulkov]
! **************************************************************************************************
   SUBROUTINE negf_sub_env_create(sub_env, negf_control, blacs_env_global, blacs_grid_layout, blacs_repeatable)
      TYPE(negf_subgroup_env_type), INTENT(out)          :: sub_env
      TYPE(negf_control_type), POINTER                   :: negf_control
      TYPE(cp_blacs_env_type), POINTER                   :: blacs_env_global
      INTEGER, INTENT(in)                                :: blacs_grid_layout
      LOGICAL, INTENT(in)                                :: blacs_repeatable

      CHARACTER(LEN=*), PARAMETER :: routineN = 'negf_sub_env_create'

      INTEGER                                            :: handle
      LOGICAL                                            :: is_split
      TYPE(mp_para_env_type), POINTER                    :: para_env_global

      CALL timeset(routineN, handle)

      CALL blacs_env_global%get(para_env=para_env_global)
      sub_env%mepos_global = para_env_global%mepos
      sub_env%mpi_comm_global = para_env_global

      ! ++ split mpi communicator if
      !    a) the requested number of processors per group > 0 (means that the split has been requested explicitly), and
      !    b) the number of subgroups is >= 2
      is_split = negf_control%nprocs > 0 .AND. negf_control%nprocs*2 <= para_env_global%num_pe

      IF (is_split) THEN
         ALLOCATE (sub_env%group_distribution(0:para_env_global%num_pe - 1))

         ALLOCATE (sub_env%para_env)
         CALL sub_env%para_env%from_split(comm=para_env_global, ngroups=sub_env%ngroups, &
                                          group_distribution=sub_env%group_distribution, subgroup_min_size=negf_control%nprocs)

         ! ++ create a new parallel environment based on the given sub-communicator)
         NULLIFY (sub_env%blacs_env)

         ! use the default (SQUARE) BLACS grid layout and non-repeatable BLACS collective operations
         ! by omitting optional parameters 'blacs_grid_layout' and 'blacs_repeatable'.
         CALL cp_blacs_env_create(sub_env%blacs_env, sub_env%para_env, blacs_grid_layout, blacs_repeatable)
      ELSE
         sub_env%para_env => para_env_global
         sub_env%ngroups = 1

         ALLOCATE (sub_env%group_distribution(0:para_env_global%num_pe - 1))
         sub_env%group_distribution(:) = 0

         sub_env%blacs_env => blacs_env_global
         CALL sub_env%blacs_env%retain()

         sub_env%para_env => para_env_global
         CALL sub_env%para_env%retain()
      END IF

      CALL timestop(handle)
   END SUBROUTINE negf_sub_env_create

! **************************************************************************************************
!> \brief Release a parallel (sub)group environment.
!> \param sub_env    parallel (sub)group environment to release
!> \par History
!>    * 06.2017 created [Sergey Chulkov]
! **************************************************************************************************
   SUBROUTINE negf_sub_env_release(sub_env)
      TYPE(negf_subgroup_env_type), INTENT(inout)        :: sub_env

      CHARACTER(LEN=*), PARAMETER :: routineN = 'negf_sub_env_release'

      INTEGER                                            :: handle

      CALL timeset(routineN, handle)

      CALL cp_blacs_env_release(sub_env%blacs_env)
      CALL mp_para_env_release(sub_env%para_env)

      IF (ALLOCATED(sub_env%group_distribution)) &
         DEALLOCATE (sub_env%group_distribution)

      sub_env%ngroups = 0

      CALL timestop(handle)
   END SUBROUTINE negf_sub_env_release
END MODULE negf_subgroup_types
